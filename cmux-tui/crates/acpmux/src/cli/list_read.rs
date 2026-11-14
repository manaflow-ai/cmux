//! The crate's one list source (agent service v2, the design doc, row 7b). A list caller opens
//! its own socket and asks for the upgrade naming `list` as that socket's first request
//! (`acpmux_client::tokio_list`); the v1 `Client` it already holds has sent requests and cannot
//! be upgraded. The daemon is the one reader of `acpmux.v2`: on its old answer (method not
//! found, or `list` not in the setting), a daemon that lists no `info-rows-v1`, or one that
//! lists a hub machine while its v2 list holds none of their rows (decision 210), [`Via::open`]
//! gives `None` and the caller runs its v1 path whole. Each v1 path is a named fallback in
//! `single_shot_list_tests.rs`.
//!
//! A read walks a view's summaries page by page and prints none of them: a summary is lossy (its
//! text cut, its lists short, five tag keys). It only leaves out the rows a form surely drops, on
//! a field it holds whole (closed or not, origin, `pendingPermissions`, `lastActivity`, a name
//! not cut); the rest are fetched as `_acpmux/sessions` writes them (`_acpmux/info` with
//! `sessionIds`), and the form's filters run again on the fetched row with today's code. Rows are
//! handed on or dropped before the next page is read, and printed in v1's order
//! (`sort_session_summaries`).

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

use acpmux_book::index::Summary;
use acpmux_client::tokio_list::{self, KEYS_PER_PAGE, ListConnection, Opened, Read};
use acpmux_client::wire::ListView;
use anyhow::{Context as _, Result};
use serde_json::{Value, json};

use crate::client::Client;
use crate::local_stream;
use crate::rpc::method;

/// A list connection on the daemon's socket.
pub(crate) type Connection = ListConnection<local_stream::ReadHalf, local_stream::WriteHalf>;

/// The v2 list of the daemon `client` is connected to: the walk's connection, and `client`, on
/// which the rows are fetched.
pub(crate) struct Source {
    connection: Box<Connection>,
    client: Arc<Client>,
}

/// How a list caller reads the session list.
pub(crate) enum Via {
    /// The v2 list on the socket the caller's client is connected to, or the caller's v1 path
    /// when its daemon has no list surface or rows by key.
    Daemon,
    /// The same, on the socket at this path (the tests' daemons).
    #[cfg(test)]
    List(std::path::PathBuf),
    /// The caller's v1 path (the tests' other side).
    #[cfg(test)]
    V1,
}

impl Via {
    /// The v2 list of the daemon the caller's client is connected to.
    pub(crate) fn daemon() -> Self {
        Self::Daemon
    }

    /// The list source `client`'s daemon serves this way, or `None` for the v1 path.
    pub(crate) async fn open(self, client: &Arc<Client>) -> Result<Option<Source>> {
        self.open_knowing(client, None).await
    }

    /// [`Via::open`] for a caller that read the daemon's `peers` already (`_acpmux/status`'s):
    /// they say whether a hub machine is listed, with no read of their own.
    pub(crate) async fn open_knowing(
        self,
        client: &Arc<Client>,
        peers: Option<&[Value]>,
    ) -> Result<Option<Source>> {
        match self {
            Self::Daemon => open_at(client.socket(), client, peers).await,
            #[cfg(test)]
            Self::List(path) => open_at(&path, client, peers).await,
            #[cfg(test)]
            Self::V1 => Ok(None),
        }
    }
}

/// The `_acpmux/status` count of the closed rows other machines list, which the v2 list does
/// not hold (a peer's closed chats are read by a relayed `page`, row 8b).
/// v1 while another machine's closed row is listed: deleted with 8b.
const CLOSED_REMOTE: &str = "closedRemoteListed";

/// Whether a form that walks the whole view reads v1, whole, from `_acpmux/status`'s `status`
/// (decision 213): while another machine lists a closed row, or when the status does not say (a
/// daemon with rows by key and without the count, or no status read). Read once, before the
/// walk: a peer's chat that closes during it is missed by that one command.
pub(crate) fn closed_remote_listed(status: Option<&Value>) -> bool {
    status.and_then(|status| status.get(CLOSED_REMOTE)?.as_u64()).is_none_or(|n| n > 0)
}

/// The `initialize` feature of a daemon whose v2 list holds the hub machines' rows (row 5h).
pub(crate) const HUB_ROWS: &str = "listHubRows";

/// The read that says whether a hub machine is listed: the cheapest v1 read naming the hosts.
/// v1 while a hub machine is listed: deleted with this read before row 13.
const HOSTS_READ: &str = "_acpmux/peers";

/// Whether `client`'s daemon lists a hub machine (`via: hub`) whose rows its v2 list lacks:
/// never when it names [`HUB_ROWS`]; else from `peers`, or one `_acpmux/peers` read. A machine
/// that joins after this read and before the walk is missed by that one command.
async fn hub_rows_missing(client: &Client, peers: Option<&[Value]>) -> Result<bool> {
    if client.daemon_lists(HUB_ROWS) {
        return Ok(false);
    }
    let via_hub = |peers: &[Value]| peers.iter().any(|peer| peer["via"] == "hub");
    if let Some(peers) = peers {
        return Ok(via_hub(peers));
    }
    let reply = client.request(HOSTS_READ, json!({})).await?;
    Ok(reply.get("peers").and_then(Value::as_array).is_some_and(|peers| via_hub(peers)))
}

/// The v2 list source on the socket at `path`, the one `client` is connected to, or `None` for
/// the caller's v1 path: a daemon without the list surface or `info-rows-v1`, or one that lists
/// a hub machine whose rows its v2 list lacks ([`hub_rows_missing`]).
async fn open_at(
    path: &std::path::Path,
    client: &Arc<Client>,
    peers: Option<&[Value]>,
) -> Result<Option<Source>> {
    if !client.daemon_lists(crate::capabilities::INFO_ROWS) || hub_rows_missing(client, peers).await? {
        return Ok(None);
    }
    let stream = local_stream::connect(path)
        .await
        .with_context(|| format!("connecting to the daemon at {}", path.display()))?;
    let (reader, writer) = local_stream::split(stream);
    match tokio_list::open(reader, writer).await.context("the list's upgrade")? {
        Opened::List(connection) => Ok(Some(Source { connection, client: client.clone() })),
        Opened::Fallback { .. } => Ok(None),
    }
}

/// One form's read: the view it walks, what a summary decides of a row, and its filters on the
/// fetched row.
pub(crate) struct Form<'f> {
    pub(crate) view: ListView,
    /// False for a row whose summary shows the form drops it, on a field the summary holds
    /// whole. Never judged on tags or on a cut text.
    pub(crate) may_keep: &'f (dyn Fn(&Summary) -> bool + Sync),
    /// The form's filters on the fetched row, today's code (`ls`'s `keeps`).
    pub(crate) keeps: &'f (dyn Fn(&Value) -> bool + Sync),
    /// `--since`: a row updated before this is left out, and as the view is newest first, the
    /// walk ends at the first such summary.
    pub(crate) cutoff: Option<u64>,
    /// `--limit`.
    pub(crate) want: Option<Want<'f>>,
    /// The fetch's `withTools` and `usage`, as the v1 read asked the list.
    pub(crate) with_tools: bool,
    pub(crate) usage: bool,
}

/// `--limit N`: the first N kept rows in v1's order, and whether the v1 list reads more after
/// them (its `nextCursor`, `cursor_after` the last row, else null). The v1 read's daemon-side
/// filters decide what that list holds.
pub(crate) struct Want<'f> {
    pub(crate) rows: usize,
    /// Whether the v1 read's daemon lists the row: from its summary when it decides it whole,
    /// else `None` and the fetched row is asked ([`Want::lists_row`]).
    pub(crate) lists: &'f (dyn Fn(&Summary) -> Option<bool> + Sync),
    pub(crate) lists_row: &'f (dyn Fn(&Value) -> bool + Sync),
}

/// What a read gives, as `ls_pages::read` does: the kept rows in v1's order, and with `--limit`
/// the cursor after the last (a string) or null when the v1 list holds no row after it.
#[derive(Debug)]
pub(crate) struct Fetched {
    pub(crate) rows: Vec<Value>,
    pub(crate) next: Option<Value>,
}

/// The key `_acpmux/info`'s `sessionIds` takes for a summary's row: a session id here, a peer's
/// or hub machine's `ORIGIN/ID`.
pub(crate) fn row_key(summary: &Summary) -> String {
    if summary.origin == "local" {
        summary.chat_id.clone()
    } else {
        format!("{}/{}", summary.origin, summary.chat_id)
    }
}

/// A summary's `extra` member `key`, parsed.
pub(crate) fn extra(summary: &Summary, key: &str) -> Option<Value> {
    serde_json::from_str::<serde_json::Map<String, Value>>(summary.extra.get())
        .ok()
        .and_then(|mut extra| extra.remove(key))
}

/// Whether the summary's chat may wait on a permission: its count is above 0, or the summary
/// does not hold it (a summary whose `extra` was bounded away holds `{}`), so only the fetched
/// row may judge it.
pub(crate) fn pending(summary: &Summary) -> bool {
    extra(summary, "pendingPermissions").and_then(|n| n.as_u64()).is_none_or(|n| n > 0)
}

/// Whether the summary's chat is closed: the one thing its `state` decides.
pub(crate) fn closed(summary: &Summary) -> bool {
    summary.state == "closed"
}

/// The summary as the row `select::name_matches` reads (its name, id, peer and qualified id),
/// or `None` when only the fetched row may judge it: its name was cut, or the summary does not
/// hold one (its `extra` bounded away).
pub(crate) fn name_probe(summary: &Summary) -> Option<Value> {
    let name = extra(summary, "name")?;
    if name.as_str().is_none_or(|n| n.ends_with('…')) {
        return None;
    }
    let mut probe = json!({"name": name, "sessionId": summary.chat_id});
    if summary.origin == "local" {
        // This daemon's rows are `local/ID` (`SessionReceipt::qualified_id`).
        probe["qualifiedSessionId"] =
            json!(format!("{}/{}", crate::session_identity::LOCAL_HOST_ID, summary.chat_id));
    } else {
        probe["peer"] = json!(summary.origin);
        probe["qualifiedSessionId"] =
            extra(summary, "qualifiedSessionId").unwrap_or_else(|| json!(row_key(summary)));
    }
    Some(probe)
}

/// The rows `keys` name, as `_acpmux/sessions` writes them, in the order asked: a hundred keys
/// a request, and the keys past a reply's bytes asked again. A key that names no row now (a
/// chat closed and purged since its summary) is left out.
pub(crate) async fn fetch(
    client: &Client,
    keys: Vec<String>,
    with_tools: bool,
    usage: bool,
) -> Result<Vec<Value>> {
    let mut queue: VecDeque<String> = keys.into();
    let mut rows = Vec::new();
    while !queue.is_empty() {
        let ask: Vec<String> = queue.drain(..queue.len().min(KEYS_PER_PAGE)).collect();
        let mut params = json!({"sessionIds": ask, "row": true});
        if with_tools {
            params["withTools"] = json!(true);
        }
        if usage {
            params["usage"] = json!(true);
        }
        let mut reply = client.request(method::MUX_INFO, params).await?;
        let got = match reply.get_mut("rows").map(Value::take) {
            Some(Value::Array(got)) => got,
            _ => anyhow::bail!("the daemon's rows by key hold no rows"),
        };
        let rest: Vec<String> = match reply.get("rest") {
            Some(Value::Array(rest)) => {
                rest.iter().filter_map(Value::as_str).map(str::to_owned).collect()
            }
            _ => Vec::new(),
        };
        if got.is_empty() && !rest.is_empty() {
            anyhow::bail!("the daemon answered none of {} keys and named them all again", rest.len());
        }
        rows.extend(got);
        for key in rest.into_iter().rev() {
            queue.push_front(key);
        }
    }
    Ok(rows)
}

/// v1's order of two rows (`hub/session_pages.rs` `sort_session_summaries`).
fn v1_order(a: &Value, b: &Value) -> std::cmp::Ordering {
    let updated = |row: &Value| row.get("updatedAt").and_then(Value::as_u64).unwrap_or(0);
    let text = |row: &Value, key: &str| row.get(key).and_then(Value::as_str).map(str::to_owned);
    updated(b)
        .cmp(&updated(a))
        .then_with(|| text(a, "sessionId").cmp(&text(b, "sessionId")))
        .then_with(|| text(a, "peer").cmp(&text(b, "peer")))
}

/// Whether the summary's row comes after `row` in v1's order.
fn after(summary: &Summary, row: &Value) -> bool {
    let at = row.get("updatedAt").and_then(Value::as_u64).unwrap_or(0);
    let peer = (summary.origin != "local").then(|| summary.origin.clone());
    let row_peer = row.get("peer").and_then(Value::as_str).map(str::to_owned);
    let row_id = row.get("sessionId").and_then(Value::as_str).unwrap_or("");
    summary.last_activity < at
        || (summary.last_activity == at
            && (summary.chat_id.as_str(), peer) > (row_id, row_peer))
}

impl Source {
    /// The rows of `form`, as the v1 read of that form keeps them. Each page's candidates are
    /// fetched and judged before the next page is read. With `--limit N` the walk ends past the
    /// N-th kept row's `updatedAt` (rows updated in its millisecond may sort before it in v1's
    /// order), then reads on only until it finds a row the v1 list holds after the last.
    pub(crate) async fn read(&mut self, form: Form<'_>) -> Result<Fetched> {
        let client = self.client.clone();
        let mut reading =
            self.connection.read(Read::Walk { view: form.view, filter: None }).await?;
        let mut kept: Vec<Value> = Vec::new();
        // The rows read until N were kept and the walk passed the N-th's millisecond, with
        // whether each was kept: some of them may come after the last kept row in v1's order.
        let mut walked: Vec<(Summary, bool)> = Vec::new();
        let mut boundary: Option<u64> = None;
        let mut ended = false;
        // Rows of the walk past the boundary, still to judge for `nextCursor`.
        let mut past: Vec<Summary> = Vec::new();
        while let Some(page) = reading.next().await? {
            let mut candidates = Vec::new();
            let mut summaries = page.rows.into_iter();
            while let Some(summary) = summaries.next() {
                if boundary.is_some_and(|at| summary.last_activity < at) {
                    past.push(summary);
                    continue;
                }
                // Past `--since` nothing is kept; with N rows kept, the v1 list's next page
                // starts here all the same.
                if form.cutoff.is_some_and(|at| summary.last_activity < at) {
                    ended = true;
                    past.push(summary);
                    past.extend(&mut summaries);
                    break;
                }
                if (form.may_keep)(&summary) {
                    candidates.push(summary);
                } else if form.want.is_some() {
                    walked.push((summary, false));
                }
            }
            let mut queue: VecDeque<Summary> = candidates.into();
            while !queue.is_empty() {
                // Ask for no more rows than the limit may still keep: a form that keeps every
                // row it fetches reads N rows, not a page.
                let room = match (&form.want, boundary) {
                    (Some(want), None) => want.rows.saturating_sub(kept.len()).max(1),
                    _ => KEYS_PER_PAGE,
                };
                let batch: Vec<Summary> = queue.drain(..queue.len().min(room)).collect();
                let keys = batch.iter().map(row_key).collect();
                let rows = fetch(&client, keys, form.with_tools, form.usage).await?;
                let kept_keys: HashSet<(String, Option<String>)> = rows
                    .iter()
                    .filter(|row| (form.keeps)(row) && !too_old(row, form.cutoff))
                    .map(identity)
                    .collect();
                kept.extend(rows.into_iter().filter(|row| kept_keys.contains(&identity(row))));
                if form.want.is_some() {
                    walked.extend(batch.into_iter().map(|summary| {
                        let id = (summary.chat_id.clone(), peer_of(&summary));
                        let was_kept = kept_keys.contains(&id);
                        (summary, was_kept)
                    }));
                }
                if let Some(want) = &form.want
                    && boundary.is_none()
                    && kept.len() >= want.rows
                {
                    kept.sort_by(v1_order);
                    boundary = kept
                        .get(want.rows - 1)
                        .and_then(|row| row.get("updatedAt").and_then(Value::as_u64));
                    // The rest of this batch's queue past the millisecond is not fetched.
                    let at = boundary.unwrap_or(0);
                    let (keep, left): (Vec<Summary>, Vec<Summary>) =
                        queue.drain(..).partition(|summary| summary.last_activity >= at);
                    queue.extend(keep);
                    past.extend(left);
                }
            }
            if ended || (boundary.is_some() && !past.is_empty()) {
                break;
            }
        }
        kept.sort_by(v1_order);
        let Some(want) = &form.want else {
            return Ok(Fetched { rows: kept, next: None });
        };
        if kept.len() < want.rows {
            return Ok(Fetched { rows: kept, next: Some(Value::Null) });
        }
        let more_kept = kept.len() > want.rows;
        kept.truncate(want.rows);
        let Some(last) = kept.last() else {
            return Ok(Fetched { rows: kept, next: Some(Value::Null) });
        };
        let cursor = crate::hub::session_pages::cursor_after(last);
        if more_kept {
            return Ok(Fetched { rows: kept, next: Some(Value::String(cursor)) });
        }
        // The rows read and not handed out that come after the last in v1's order, then the
        // walk's rest: the first one the v1 list holds names a next page.
        let mut unsure = Vec::new();
        let read_after = walked
            .into_iter()
            .filter(|(summary, was_kept)| !was_kept && after(summary, last))
            .map(|(summary, _)| summary)
            .chain(past);
        for summary in read_after {
            match (want.lists)(&summary) {
                Some(true) => return Ok(Fetched { rows: kept, next: Some(Value::String(cursor)) }),
                Some(false) => {}
                None => unsure.push(row_key(&summary)),
            }
        }
        if lists_any(&client, unsure, want, form.with_tools).await? {
            return Ok(Fetched { rows: kept, next: Some(Value::String(cursor)) });
        }
        while let Some(page) = reading.next().await? {
            let mut unsure = Vec::new();
            for summary in page.rows {
                match (want.lists)(&summary) {
                    Some(true) => {
                        return Ok(Fetched { rows: kept, next: Some(Value::String(cursor)) });
                    }
                    Some(false) => {}
                    None => unsure.push(row_key(&summary)),
                }
            }
            if lists_any(&client, unsure, want, form.with_tools).await? {
                return Ok(Fetched { rows: kept, next: Some(Value::String(cursor)) });
            }
        }
        Ok(Fetched { rows: kept, next: Some(Value::Null) })
    }

    /// Every row of `view` whose summary `may_keep` passes, fetched, in v1's order: what a
    /// form that reads the whole view (`pending`, `send --tag`, MCP `ls`) reads.
    pub(crate) async fn rows(
        &mut self,
        view: ListView,
        may_keep: &(dyn Fn(&Summary) -> bool + Sync),
    ) -> Result<Vec<Value>> {
        let form = Form {
            view,
            may_keep,
            keeps: &|_| true,
            cutoff: None,
            want: None,
            with_tools: false,
            usage: false,
        };
        Ok(self.read(form).await?.rows)
    }

    /// The pages the walk asked for and the most it held not handed out, for the gates.
    #[cfg(test)]
    pub(crate) fn connection(&self) -> &Connection {
        &self.connection
    }
}

/// Whether the v1 list holds any of the rows `keys` name, read from the fetched rows.
async fn lists_any(
    client: &Client,
    keys: Vec<String>,
    want: &Want<'_>,
    with_tools: bool,
) -> Result<bool> {
    if keys.is_empty() {
        return Ok(false);
    }
    let rows = fetch(client, keys, with_tools, false).await?;
    Ok(rows.iter().any(|row| (want.lists_row)(row)))
}

fn too_old(row: &Value, cutoff: Option<u64>) -> bool {
    cutoff.is_some_and(|at| row.get("updatedAt").and_then(Value::as_u64).unwrap_or(0) < at)
}

/// One row: its session id and its peer (none here).
fn identity(row: &Value) -> (String, Option<String>) {
    let text = |key: &str| row.get(key).and_then(Value::as_str).map(str::to_owned);
    (text("sessionId").unwrap_or_default(), text("peer"))
}

fn peer_of(summary: &Summary) -> Option<String> {
    (summary.origin != "local").then(|| summary.origin.clone())
}
