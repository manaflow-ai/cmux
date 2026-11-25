//! The relay seam (row 8b, decisions 265 to 270). A local `page` that names another origin, a
//! filter by origin on view `all` or keys of that origin the index does not hold, is answered
//! by asking that origin over its link through a [`PageRelay`], when the relay takes that
//! origin now. The answer is renamed as the mirror renames a row and handed to the asker; no
//! step writes the index, its log or a peer store. Otherwise the page is answered at once, as
//! before, from the index and the [`PageProvider`].

use super::keyed_page::{Entry, KeyedPlan};
use super::*;
use crate::wire::{ListFilter, ListKey, ListView, Page, PageKey, PageResult};
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

/// How long a relayed request waits for its origin's answer (decision 267). Past it the asker
/// gets `error` (a view page) or `unknown` (keys), and a later answer is dropped.
pub const RELAY_PAGE_DEADLINE: Duration = Duration::from_secs(10);
/// Relayed requests in flight to one origin. The next one answers `busy` (decision 267).
pub const RELAY_IN_FLIGHT: usize = 16;
/// The error code of a request past [`RELAY_IN_FLIGHT`].
pub const RELAY_BUSY: &str = "busy";
/// The error code of a relayed view page whose origin did not answer: its deadline passed or
/// its link ended.
pub const RELAY_FAILED: &str = "relay_failed";
const PEER_LOCAL: &str = "local";

/// Why a relayed request has no rows: the origin's own `error` code, or the relay's.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelayFailed {
    pub code: String,
    pub message: String,
}

/// The origin's page as it sent it: rows in peer form, every row and key of origin `local`.
pub type RelayAnswer = Result<PageResult<Summary>, RelayFailed>;
pub type RelayFuture = Pin<Box<dyn Future<Output = RelayAnswer> + Send>>;

/// Asks an origin over its link (8b PR 4 builds it on the mirror's link).
pub trait PageRelay: Send + Sync {
    /// Whether `origin`'s pages go to it now: `peers` on, the origin's mirror running and its
    /// peer naming `listPages` (decision 265). Otherwise the provider answers.
    fn relays(&self, origin: &str) -> bool;
    /// Sends `request` to `origin` in the peer's terms: its filter and every key `local`
    /// (decision 266). Called once per request, after its slot is taken.
    fn page(&self, origin: &str, request: Page) -> RelayFuture;
}

#[derive(Default)]
pub(super) struct RelayState {
    relay: Mutex<Option<Arc<dyn PageRelay>>>,
    in_flight: Mutex<HashMap<String, usize>>,
    foreign_rows: AtomicU64,
}

/// The slots one relayed request holds, one per origin it asks, given back when it is
/// answered, fails or is dropped.
struct Slots {
    state: Arc<RelayState>,
    origins: Vec<String>,
}

impl Drop for Slots {
    fn drop(&mut self) {
        if let Ok(mut in_flight) = self.state.in_flight.lock() {
            for origin in &self.origins {
                if let Some(count) = in_flight.get_mut(origin) {
                    *count = count.saturating_sub(1);
                    if *count == 0 {
                        in_flight.remove(origin);
                    }
                }
            }
        }
    }
}

/// What [`Hub::relayed_page`] makes of a local page.
pub enum Relayed {
    /// Answered at once: every key it names is held here or by the provider.
    Done(Frame),
    /// An origin it asks has [`RELAY_IN_FLIGHT`] requests in flight.
    Busy,
    /// Sent; [`RelayedPage::answer`] waits for the origins.
    Sent(RelayedPage),
}

/// A relayed page in flight. Dropping it gives its slots back.
pub struct RelayedPage {
    _slots: Slots,
    hub: Arc<RelayState>,
    work: Work,
}

enum Work {
    View { origin: String, sid: String, max: usize, answer: RelayFuture },
    Keys { plan: KeyedPlan, asks: Vec<(String, RelayFuture)> },
}

/// Why a relayed page answers `error`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelayError {
    pub code: String,
    pub message: String,
}

impl Hub {
    /// The relay a local page that names another origin is asked through (row 8b).
    pub fn set_page_relay(&self, relay: Arc<dyn PageRelay>) {
        if let Ok(mut slot) = self.relay.relay.lock() {
            *slot = Some(relay);
        }
    }

    /// Rows of a third origin in relayed answers, dropped (decision 269).
    pub fn relay_foreign_rows(&self) -> u64 {
        self.relay.foreign_rows.load(Ordering::Relaxed)
    }

    /// Relayed requests in flight to `origin`.
    pub fn relay_in_flight(&self, origin: &str) -> usize {
        self.relay
            .in_flight
            .lock()
            .map_or(0, |in_flight| in_flight.get(origin).copied().unwrap_or(0))
    }

    fn page_relay(&self) -> Option<Arc<dyn PageRelay>> {
        self.relay.relay.lock().ok().and_then(|slot| slot.clone())
    }

    /// A local `page` the relay answers, or `None` when [`Hub::page`] answers it at once: no
    /// relay, an origin the relay does not take now, or a page that names no other origin.
    pub fn relayed_page(&self, request: &Page) -> Option<Result<Relayed, HubError>> {
        let relay = self.page_relay()?;
        if request.stream.as_str() != "list" || request.turns || request.fold.is_some() {
            return None;
        }
        if let Some(keys) = request.keys.as_ref() {
            let names_other = keys.iter().any(
                |key| matches!(key, PageKey::Summary(key) if key.origin != PEER_LOCAL && relay.relays(&key.origin)),
            );
            if !names_other || request.view == Some(ListView::Folders) {
                return None;
            }
            return Some(self.relay_keys(request, keys, relay.as_ref()));
        }
        let origin = relayed_view_origin(request)?;
        if !relay.relays(origin) {
            return None;
        }
        Some(self.relay_view(request, origin, relay.as_ref()))
    }

    fn relay_view(
        &self,
        request: &Page,
        origin: &str,
        relay: &dyn PageRelay,
    ) -> Result<Relayed, HubError> {
        let max = request.max_bytes as usize;
        if max > crate::wire::MAX_PAGE_BYTES || max <= 8192 + request.sid.len() {
            return Err(HubError::InvalidPage);
        }
        // Each row and key the origin sends comes back with its name for `local`: ask for
        // less by what that renaming can add, so the renamed page fits the asker's budget.
        let growth = name_growth(origin)?;
        let reserve = growth.saturating_mul(MAX_WINDOW_ROWS + 2);
        let peer_max = max.saturating_sub(reserve);
        if peer_max <= 8192 + request.sid.len() {
            return Err(HubError::InvalidPage);
        }
        let to_peer = |position: &Option<Position>| -> Result<Option<Position>, HubError> {
            match position {
                None => Ok(None),
                Some(Position::List(key)) if key.origin == origin => {
                    Ok(Some(Position::List(ListKey { origin: PEER_LOCAL.into(), ..key.clone() })))
                }
                Some(_) => Err(HubError::InvalidPage),
            }
        };
        let filter = request.filter.clone().unwrap_or_default();
        let peer = Page {
            sid: request.sid.clone(),
            stream: request.stream.clone(),
            before: to_peer(&request.before)?,
            after: to_peer(&request.after)?,
            keys: None,
            view: Some(ListView::All),
            max_bytes: u32::try_from(peer_max).map_err(|_| HubError::InvalidPage)?,
            filter: Some(ListFilter {
                workspace: filter.workspace,
                origin: Some(PEER_LOCAL.into()),
                state: filter.state,
                ..ListFilter::default()
            }),
            edition: None,
            fold: None,
            turns: false,
        };
        let Some(slots) = self.take_slots(std::slice::from_ref(&origin.to_owned())) else {
            return Ok(Relayed::Busy);
        };
        let answer = relay.page(origin, peer);
        Ok(Relayed::Sent(RelayedPage {
            _slots: slots,
            hub: self.relay.clone(),
            work: Work::View { origin: origin.to_owned(), sid: request.sid.clone(), max, answer },
        }))
    }

    fn relay_keys(
        &self,
        request: &Page,
        keys: &[PageKey],
        relay: &dyn PageRelay,
    ) -> Result<Relayed, HubError> {
        let max = request.max_bytes as usize;
        if max > crate::wire::MAX_PAGE_BYTES
            || max <= 8192 + request.sid.len()
            || keys.is_empty()
            || keys.len() > 100
            || request.before.is_some()
            || request.after.is_some()
        {
            return Err(HubError::InvalidPage);
        }
        let plan =
            self.keyed_plan(request, keys, false, Some(&|origin: &str| relay.relays(origin)))?;
        let mut plan = plan;
        let mut origins: Vec<(String, usize)> = Vec::new();
        for entry in &plan.entries {
            if let Entry::Ask(key) = entry {
                match origins.iter_mut().find(|(origin, _)| *origin == key.origin) {
                    Some((_, count)) => *count += 1,
                    None => origins.push((key.origin.clone(), 1)),
                }
            }
        }
        // The room the plan leaves is shared by the origins asked, less what renaming their
        // rows adds. An origin whose share is under a page's least budget is not asked: its keys
        // go to `rest`, and the asker asks again.
        let share = max.saturating_sub(plan.used) / origins.len().max(1);
        let mut budgets: Vec<(String, usize)> = Vec::new();
        for (origin, count) in origins {
            let peer_max = share.saturating_sub(name_growth(&origin)?.saturating_mul(count));
            if peer_max > 8192 + request.sid.len() {
                budgets.push((origin, peer_max.min(crate::wire::MAX_PAGE_BYTES)));
            } else {
                for entry in &mut plan.entries {
                    if let Entry::Ask(key) = entry
                        && key.origin == origin
                    {
                        *entry = Entry::Rest(key.clone());
                    }
                }
            }
        }
        if budgets.is_empty() {
            return plan.finish().map(Relayed::Done);
        }
        let origins = budgets.iter().map(|(origin, _)| origin.clone()).collect::<Vec<_>>();
        let Some(slots) = self.take_slots(&origins) else { return Ok(Relayed::Busy) };
        let asks = budgets
            .into_iter()
            .map(|(origin, peer_max)| {
                let asked = plan
                    .entries
                    .iter()
                    .filter_map(|entry| match entry {
                        Entry::Ask(key) if key.origin == origin => {
                            Some(PageKey::Summary(ListKey {
                                origin: PEER_LOCAL.into(),
                                ..key.clone()
                            }))
                        }
                        _ => None,
                    })
                    .collect::<Vec<_>>();
                let peer = Page {
                    sid: request.sid.clone(),
                    stream: request.stream.clone(),
                    before: None,
                    after: None,
                    keys: Some(asked),
                    view: None,
                    max_bytes: u32::try_from(peer_max).map_err(|_| HubError::InvalidPage)?,
                    filter: None,
                    edition: None,
                    fold: None,
                    turns: false,
                };
                let answer = relay.page(&origin, peer);
                Ok((origin, answer))
            })
            .collect::<Result<Vec<_>, HubError>>()?;
        Ok(Relayed::Sent(RelayedPage {
            _slots: slots,
            hub: self.relay.clone(),
            work: Work::Keys { plan, asks },
        }))
    }

    /// All of `origins` or none: a request takes one slot per origin it asks.
    fn take_slots(&self, origins: &[String]) -> Option<Slots> {
        let mut in_flight = self.relay.in_flight.lock().ok()?;
        if origins
            .iter()
            .any(|origin| in_flight.get(origin).copied().unwrap_or(0) >= RELAY_IN_FLIGHT)
        {
            return None;
        }
        for origin in origins {
            *in_flight.entry(origin.clone()).or_insert(0) += 1;
        }
        Some(Slots { state: self.relay.clone(), origins: origins.to_vec() })
    }
}

impl RelayedPage {
    /// Waits for the origins, at most [`RELAY_PAGE_DEADLINE`] from now, and builds the asker's
    /// frame. A view page whose origin failed is an error; a key it failed to answer is
    /// `unknown`.
    pub async fn answer(self) -> Result<Frame, RelayError> {
        let deadline = tokio::time::Instant::now() + RELAY_PAGE_DEADLINE;
        let state = self.hub.clone();
        match self.work {
            Work::View { origin, sid, max, answer } => {
                let page = match tokio::time::timeout_at(deadline, answer).await {
                    Err(_) => {
                        return Err(RelayError {
                            code: RELAY_FAILED.into(),
                            message: format!("origin {origin:?} did not answer in time"),
                        });
                    }
                    Ok(Err(failed)) => {
                        return Err(RelayError { code: failed.code, message: failed.message });
                    }
                    Ok(Ok(page)) => page,
                };
                view_frame(&state, &origin, sid, max, page)
            }
            Work::Keys { mut plan, asks } => {
                for (origin, answer) in asks {
                    let answer =
                        tokio::time::timeout_at(deadline, answer).await.ok().and_then(Result::ok);
                    settle(&state, &mut plan, &origin, answer)?;
                }
                plan.finish().map_err(|error| RelayError {
                    code: "invalid_params".into(),
                    message: error.to_string(),
                })
            }
        }
    }
}

/// The origin a view page names, when the relay can carry it: view `all` filtered by one other
/// origin, with no table filter, anchored, if at all, on that origin's key (decision 266).
pub(super) fn relayed_view_origin(request: &Page) -> Option<&str> {
    if request.view != Some(ListView::All) || request.edition.is_some() {
        return None;
    }
    let filter = request.filter.as_ref()?;
    let ListFilter { workspace: _, origin, state: _, family, folder, forks, cold } = filter;
    let origin = origin.as_deref().filter(|origin| *origin != PEER_LOCAL)?;
    if family.is_some() || folder.is_some() || forks.is_some() || *cold {
        return None;
    }
    let anchored_here = match (&request.before, &request.after) {
        (None, None) => true,
        (Some(Position::List(key)), None) | (None, Some(Position::List(key))) => {
            key.origin == origin
        }
        _ => false,
    };
    anchored_here.then_some(origin)
}

/// What naming `origin` adds to one row or key over naming `local`, in JSON bytes.
fn name_growth(origin: &str) -> Result<usize, HubError> {
    let named = serde_json::to_vec(origin).map_err(FrameError::Encode)?.len();
    Ok(named.saturating_sub(PEER_LOCAL.len() + 2))
}

/// A row of the origin's answer in this machine's form: its `local` named `origin`; a row of
/// another origin is dropped and counted (decision 269).
fn rename_row(state: &RelayState, origin: &str, mut row: Summary) -> Option<Summary> {
    if row.origin != PEER_LOCAL {
        state.foreign_rows.fetch_add(1, Ordering::Relaxed);
        return None;
    }
    row.origin = origin.to_owned();
    Some(row)
}

fn rename_key(origin: &str, key: ListKey) -> Option<ListKey> {
    (key.origin == PEER_LOCAL).then(|| ListKey { origin: origin.to_owned(), ..key })
}

fn view_frame(
    state: &RelayState,
    origin: &str,
    sid: String,
    max: usize,
    page: PageResult<Summary>,
) -> Result<Frame, RelayError> {
    let rows =
        page.rows.into_iter().filter_map(|row| rename_row(state, origin, row)).collect::<Vec<_>>();
    let reply = PageResult {
        sid,
        rows,
        has_before: page.has_before,
        has_after: page.has_after,
        cold_unread: page.cold_unread,
        deeper: page.deeper.into_iter().filter_map(|key| rename_key(origin, key)).collect(),
        before_key: page.before_key.and_then(|key| rename_key(origin, key)),
        after_key: page.after_key.and_then(|key| rename_key(origin, key)),
        missing: Vec::new(),
        unknown: Vec::new(),
        rest: Vec::new(),
    };
    let frame = Frame::json(FrameKind::Page, &reply)
        .map_err(|error| RelayError { code: RELAY_FAILED.into(), message: error.to_string() })?;
    if frame.encoded_len() > max {
        return Err(RelayError {
            code: RELAY_FAILED.into(),
            message: format!("origin {origin:?} answered past the page's byte budget"),
        });
    }
    Ok(frame)
}

/// Puts one origin's answer into the plan's asked keys: a row it sent, its `missing` as
/// `missing` (the owner answered), its `rest` as `rest`, and anything else `unknown`.
fn settle(
    state: &RelayState,
    plan: &mut KeyedPlan,
    origin: &str,
    answer: Option<PageResult<Summary>>,
) -> Result<(), RelayError> {
    let encode = |error: serde_json::Error| RelayError {
        code: RELAY_FAILED.into(),
        message: error.to_string(),
    };
    let Some(page) = answer else {
        for entry in &mut plan.entries {
            if let Entry::Ask(key) = entry
                && key.origin == origin
            {
                *entry = Entry::Unknown(key.clone());
            }
        }
        return Ok(());
    };
    let mut rows: HashMap<String, Summary> = HashMap::new();
    for row in page.rows {
        if let Some(row) = rename_row(state, origin, row) {
            rows.insert(row.chat_id.clone(), row);
        }
    }
    let named = |keys: &[ListKey], chat_id: &str| {
        keys.iter().any(|key| key.origin == PEER_LOCAL && key.chat_id == chat_id)
    };
    for entry in &mut plan.entries {
        let Entry::Ask(key) = entry else { continue };
        if key.origin != origin {
            continue;
        }
        *entry = if let Some(row) = rows.remove(&key.chat_id) {
            Entry::Row(serde_json::value::to_raw_value(&row).map_err(encode)?)
        } else if named(&page.missing, &key.chat_id) {
            Entry::Missing(key.clone())
        } else if named(&page.rest, &key.chat_id) {
            Entry::Rest(key.clone())
        } else {
            Entry::Unknown(key.clone())
        };
    }
    Ok(())
}

#[cfg(test)]
#[path = "relay_tests.rs"]
mod tests;
