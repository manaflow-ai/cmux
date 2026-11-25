//! Cards (decisions 253, 254): state a person can act on, made by one record and patched by
//! later ones. A card row holds the small facts the translator folds across its records as
//! fields, and its records' inputs raw: a `records` body the actor reads again from the log at
//! each write, plus the few strings a decided card draws without a blob (`BodySource::RawField`).
//! The page reads each listed record with the one-record parser v1 used and folds nothing.
//! State keeps, for each open card, its key's hash, its row, the folded facts and one fixed-width
//! entry for each listed record; no text.
use super::{
    BodyField, BodySource, Change, Error, OwnedRow, RawLine, State, cut, input, prompt_hash,
};
use crate::row::RowKind;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, value::RawValue};
use std::collections::BTreeMap;

/// The most cards open at once, of every kind together (asks apart, at their 32).
const MAX_CARDS: usize = 64;
/// The most bytes all open cards' state holds, inside the translator's segment.
pub(super) const MAX_CARD_BYTES: usize = 6 * 1024;
/// The held items an agent pair lists, as the view shows them; past it they are counted only.
const MAX_HELD: usize = 20;
/// The offers one card lists (a group's suggested tasks); past it the oldest leaves, counted.
const MAX_OFFERS: usize = 5;
/// A memory offer's facts, as the view keeps them.
const MAX_FACTS: usize = 3;

/// The strings a card reads again raw, with their caps: a static key and number, never a
/// record's. A cut is counted where the translator first reads the line (`Cards::cut_once`).
const PEER: (&str, usize) = ("peer", 256);
const PEER_NAME: (&str, usize) = ("peerName", 256);
const PAIR_ERROR: (&str, usize) = ("error", 1024);
const FILE: (&str, usize) = ("file", 512);
const COACH_ID: (&str, usize) = ("coachId", 64);
const PRESET: (&str, usize) = ("preset", 128);

/// An agent pair's pause reasons, as the view reads them; any other reads as the first.
const REASONS: [&str; 4] = ["alternating", "repeating", "cap", "release_failed"];
/// A suggested task's outcome, by its mark.
const OUTCOMES: [&str; 3] = ["accepted", "dismissed", "here"];
/// A preset approval's outcome, by its mark.
const PRESET_OUTCOMES: [&str; 2] = ["approved", "declined"];

/// A listed record's role in its card.
const BASE: u8 = 0;
const HELD: u8 = 1;
/// Past every outcome mark, which an offer's entry holds in the same byte.
const DECISION: u8 = u8::MAX;
/// A suggested task's outcome mark: none yet, or 1 + its index in `OUTCOMES`.
const UNDECIDED: u8 = 0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) enum CardKind {
    AgentPair,
    Memory,
    Coach,
    Preset,
    Offers,
    PlanBuild,
}
impl CardKind {
    /// The view's row kind, the row's `card` field.
    fn name(self) -> &'static str {
        match self {
            CardKind::AgentPair => "agentPair",
            CardKind::Memory => "memoryOffer",
            CardKind::Coach => "promptCoach",
            CardKind::Preset => "presetApproval",
            CardKind::Offers => "sessionOffer",
            CardKind::PlanBuild => "plan_build",
        }
    }
    /// The most cards of the kind open at once; together they stay within `MAX_CARDS`.
    fn most(self) -> usize {
        match self {
            CardKind::AgentPair | CardKind::PlanBuild => 4,
            CardKind::Memory | CardKind::Preset => 16,
            CardKind::Coach | CardKind::Offers => 8,
        }
    }
}

/// One record a card lists: what it stands for (`key`, a hash), its line, and its role.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Listed {
    key: u64,
    line: RawLine,
    mark: u8,
}

/// What the translator folds across a card's records; numbers and flags only.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
enum Facts {
    AgentPair {
        reason: u8,
        count: u32,
        window: Option<u64>,
        error: bool,
        released: u32,
        dropped: u32,
        held: u32,
        resumed: bool,
    },
    /// Each fact's hash; which are accepted and dismissed, by bit.
    Memory {
        facts: Vec<u64>,
        accepted: u8,
        dismissed: u8,
        created: bool,
    },
    /// `None` while offered, the rewrite's corrections once it came.
    Coach {
        corrections: Option<u32>,
    },
    Preset {
        requests: u32,
        outcome: Option<u8>,
    },
    Offers {
        /// Several offers under one `groupId`: decided only offer by offer, never as a whole.
        group: bool,
    },
    PlanBuild {
        kept: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Card {
    kind: CardKind,
    key: u64,
    id: u64,
    rev: u32,
    at: u64,
    turn: Option<u64>,
    facts: Facts,
    listed: Vec<Listed>,
}
impl Card {
    /// Each kind's count and bytes, for the bound tests.
    #[cfg(test)]
    pub(super) fn kinds(cards: &[Card]) -> Vec<(String, usize)> {
        let mut out: Vec<(String, usize)> = Vec::new();
        for card in cards {
            let name = format!("card {}", card.kind.name());
            match out.iter_mut().find(|(seen, _)| seen.starts_with(&name)) {
                Some(entry) => entry.1 += card.bytes(),
                None => out.push((name, card.bytes())),
            }
        }
        let counts: Vec<usize> = out
            .iter()
            .map(|(name, _)| {
                cards.iter().filter(|c| format!("card {}", c.kind.name()) == *name).count()
            })
            .collect();
        out.into_iter()
            .zip(counts)
            .map(|((name, bytes), n)| (format!("{name} x{n}"), bytes))
            .collect()
    }
    /// The bytes the card holds in the segment, as the checkpoint encodes it: O(card).
    fn bytes(&self) -> usize {
        super::checkpoint::encoded_len(self)
    }
}

/// The line a record came on, as a card lists it.
#[derive(Clone, Copy, Debug)]
pub(super) struct At<'a> {
    pub raw: &'a RawValue,
    pub line: RawLine,
}

fn key(kind: CardKind, id: &str) -> u64 {
    prompt_hash(&format!("{}\0{id}", kind.name()))
}
fn str_of<'a>(msg: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    msg.get(key).and_then(Value::as_str).filter(|value| !value.is_empty())
}
fn trimmed<'a>(msg: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    msg.get(key).and_then(Value::as_str).map(str::trim).filter(|value| !value.is_empty())
}
/// A count as the view reads it: a finite number at least 0, floored; else none.
fn count(msg: &Map<String, Value>, key: &str) -> Option<u64> {
    let value = msg.get(key)?;
    value.as_u64().or_else(|| {
        // A float cast saturates: a finite count past u64 reads as the most there is.
        value.as_f64().filter(|n| n.is_finite() && *n >= 0.0).map(|n| n.floor() as u64)
    })
}
/// The preset approval's `text()`: a string trimmed (empty is none), a number or flag as its
/// text, an object as its JSON; null is none.
fn preset_text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::Null => None,
        Value::String(text) => Some(text.trim()).filter(|t| !t.is_empty()).map(str::to_owned),
        other => Some(other.to_string()),
    }
}
fn json(value: Value) -> String {
    serde_json::to_string(&value).unwrap_or_else(|_| "null".into())
}

impl State {
    /// The open card of `key`, by index.
    fn card_at(&self, key: u64) -> Option<usize> {
        self.cards.iter().position(|card| card.key == key)
    }
    pub(super) fn card_bytes(&self) -> usize {
        self.cards.iter().map(Card::bytes).fold(0, usize::saturating_add)
    }
    /// Counts a cut where the translator first reads a string a card shows (decision 254): the
    /// actor's re-reads cut it the same way and count nothing.
    fn cut_once(&mut self, msg: &Map<String, Value>, (key, cap): (&str, usize)) {
        if let Some(value) = msg.get(key).and_then(Value::as_str)
            && cut(value, cap).len() < value.len()
        {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
    }
    /// A record its one-record parser would refuse: no row, counted.
    fn refused(&mut self) {
        self.refused_records = self.refused_records.saturating_add(1);
    }
    /// A record for a card that is not among the keys (it left past a cap, or never opened): a
    /// notice row of its own listing it, counted (decision 253, c).
    fn orphan(
        &mut self,
        kind: &'static str,
        at: At<'_>,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        self.orphan_records = self.orphan_records.saturating_add(1);
        let mut row = self.row(RowKind::Notice, out)?;
        row.field("notice", kind);
        out.row(&row);
        out.emit(Change::Body {
            id: row.id,
            field: BodyField::Records,
            append: false,
            source: BodySource::Records(vec![at.line]),
        });
        row.open = false;
        out.row(&row);
        Ok(())
    }

    /// A new card's row, written settled, then held under its key unless `done`.
    fn open_card(
        &mut self,
        kind: CardKind,
        key: u64,
        facts: Facts,
        listed: Vec<Listed>,
        done: bool,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        let row = self.row(RowKind::Card, out)?;
        let card =
            Card { kind, key, id: row.id, rev: 1, at: row.at, turn: row.turn, facts, listed };
        let mut row = card_row(&card);
        row.open = true;
        out.row(&row);
        self.card_bodies(&card, out);
        row.open = false;
        out.row(&row);
        if done {
            return Ok(());
        }
        // The newest card always gets its place: past a cap the oldest leaves, counted.
        loop {
            let of_kind = self.cards.iter().filter(|held| held.kind == kind).count();
            if of_kind >= kind.most() {
                let oldest = self.cards.iter().position(|held| held.kind == kind);
                self.leave(oldest.unwrap_or(0));
            } else if self.cards.len() >= MAX_CARDS {
                self.leave(0);
            } else {
                break;
            }
        }
        self.cards.push(card);
        self.bound_cards(key);
        Ok(())
    }
    /// A held card's patch, its rev rising; it leaves the keys after it when `done`.
    fn patch_card(&mut self, at: usize, done: bool, out: &mut input::Output<'_>) {
        let Some(card) = self.cards.get_mut(at) else { return };
        card.rev = card.rev.saturating_add(1);
        let card = card.clone();
        self.card_bodies(&card, out);
        out.emit(Change::Patch(card_row(&card)));
        if done {
            self.cards.remove(at);
        } else {
            self.bound_cards(card.key);
        }
    }
    /// Past the byte budget the oldest card other than `keep` leaves, counted.
    fn bound_cards(&mut self, keep: u64) {
        while self.card_bytes() > MAX_CARD_BYTES
            && let Some(oldest) = self.cards.iter().position(|card| card.key != keep)
        {
            self.leave(oldest);
        }
    }
    fn leave(&mut self, at: usize) {
        if at < self.cards.len() {
            self.cards.remove(at);
            self.evicted_cards = self.evicted_cards.saturating_add(1);
        }
    }
    /// A card's records and its raw strings, read again by the actor at this write.
    fn card_bodies(&self, card: &Card, out: &mut input::Output<'_>) {
        out.emit(Change::Body {
            id: card.id,
            field: BodyField::Records,
            append: false,
            source: BodySource::Records(card.listed.iter().map(|listed| listed.line).collect()),
        });
        let base = card.listed.iter().find(|listed| listed.mark == BASE).map(|listed| listed.line);
        let newest = card.listed.last().map(|listed| listed.line);
        let raw: &[((&'static str, usize), Option<RawLine>)] = match &card.facts {
            Facts::AgentPair { error, .. } => {
                &[(PEER, base), (PEER_NAME, base), (PAIR_ERROR, if *error { base } else { None })]
            }
            Facts::Memory { .. } => &[(FILE, base)],
            Facts::Coach { .. } => &[(COACH_ID, card.listed.first().map(|listed| listed.line))],
            Facts::Preset { .. } => &[(PRESET, newest)],
            Facts::Offers { .. } | Facts::PlanBuild { .. } => &[],
        };
        for ((key, cap), line) in raw {
            if let Some(RawLine { place, span }) = line {
                out.emit(Change::Body {
                    id: card.id,
                    field: BodyField::Card(key),
                    append: false,
                    source: BodySource::RawField { place: *place, span: *span, key, cap: *cap },
                });
            }
        }
    }
}

/// A card's row: its `card` name and its folded facts as fields, settled.
fn card_row(card: &Card) -> OwnedRow {
    let mut fields = BTreeMap::new();
    fields.insert("card".into(), json(Value::String(card.kind.name().into())));
    let mut put = |key: &str, value: Value| {
        fields.insert(key.into(), json(value));
    };
    match &card.facts {
        Facts::AgentPair { reason, count, window, released, dropped, held, resumed, .. } => {
            let reason = REASONS.get(usize::from(*reason)).copied().unwrap_or("alternating");
            put("reason", Value::String(reason.into()));
            put("count", Value::from(*count));
            if let Some(window) = window {
                put("windowSecs", Value::from(*window));
            }
            put("released", Value::from(*released));
            put("dropped", Value::from(*dropped));
            put("held", Value::from(*held));
            if *resumed {
                put("resumed", Value::Bool(true));
            }
        }
        Facts::Memory { facts, accepted, dismissed, created } => {
            let bits = |mask: u8| -> Value {
                (0..facts.len())
                    .filter(|index| {
                        u32::try_from(*index).is_ok_and(|i| mask & (1u8 << i.min(7)) != 0)
                    })
                    .map(Value::from)
                    .collect()
            };
            put("facts", Value::from(facts.len()));
            put("accepted", bits(*accepted));
            put("dismissed", bits(*dismissed));
            if *created {
                put("created", Value::Bool(true));
            }
        }
        Facts::Coach { corrections } => {
            if let Some(corrections) = corrections {
                put("corrections", Value::from(*corrections));
            }
        }
        Facts::Preset { requests, outcome } => {
            put("requests", Value::from(*requests));
            if let Some(outcome) = outcome.and_then(|o| PRESET_OUTCOMES.get(usize::from(o))) {
                put("outcome", Value::String((*outcome).into()));
            }
        }
        Facts::Offers { .. } => {
            // Each offer's place in `records`, its outcome, and the decision that names its child.
            let mut outcomes = Vec::new();
            for (index, listed) in card.listed.iter().enumerate() {
                if listed.mark == DECISION {
                    continue;
                }
                let mut offer = Map::new();
                offer.insert("offer".into(), Value::from(index));
                if let Some(word) =
                    listed.mark.checked_sub(1).and_then(|o| OUTCOMES.get(usize::from(o)))
                {
                    offer.insert("outcome".into(), Value::String((*word).into()));
                }
                if let Some(decision) = card
                    .listed
                    .iter()
                    .position(|other| other.mark == DECISION && other.key == listed.key)
                {
                    offer.insert("decision".into(), Value::from(decision));
                }
                outcomes.push(Value::Object(offer));
            }
            put("offers", Value::Array(outcomes));
        }
        Facts::PlanBuild { kept } => {
            if *kept {
                put("kept", Value::Bool(true));
            }
        }
    }
    OwnedRow {
        id: card.id,
        rev: card.rev,
        kind: RowKind::Card,
        turn: card.turn,
        // A card never folds under a turn's group row: it is no part of the group's shown line.
        group: None,
        at: card.at,
        open: false,
        bytes: 0,
        lines: 0,
        fields,
    }
}

/// The records that make and patch cards, by kind.
pub(super) fn record(
    state: &mut State,
    kind: &str,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<bool, Error> {
    let msg: Map<String, Value> = serde_json::from_str(at.raw.get()).unwrap_or_default();
    match kind {
        "agent_pair_paused" => paused(state, &msg, at, out)?,
        "agent_pair_held" => held(state, &msg, at, out)?,
        "agent_pair_released" | "agent_pair_dropped" => {
            settle_held(state, &msg, kind == "agent_pair_released", at, out)?;
        }
        "agent_pair_resumed" => resumed(state, &msg, at, out)?,
        "memory_offer" => memory_offer(state, &msg, at, out)?,
        "memory_resolved" => memory_resolved(state, &msg, at, out)?,
        "coach_offer" => coach_offer(state, &msg, at, out)?,
        "coach" => coach(state, &msg, at, out)?,
        "preset_approval_request" => preset_request(state, &msg, at, out)?,
        "preset_approval_decision" => preset_decision(state, &msg, at, out)?,
        "session_offer" => session_offer(state, &msg, at, out)?,
        "session_offer_decision" => offer_decision(state, &msg, at, out)?,
        "plan_build" => plan_build(state, &msg, at, out)?,
        _ => return Ok(false),
    }
    Ok(true)
}

fn listed(key: u64, at: At<'_>, mark: u8) -> Listed {
    Listed { key, line: at.line, mark }
}

/// `agent_pair_paused`: the pair's card, or the open one of the same peer again with this pause's
/// reason (the view's `reduceAgentPair`). A pause after a resume opens a new card, which takes
/// the items still held.
fn paused(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let Some(peer) = str_of(msg, "peer") else {
        state.refused();
        return Ok(());
    };
    state.cut_once(msg, PEER);
    state.cut_once(msg, PEER_NAME);
    let error = str_of(msg, "error").is_some();
    if error {
        state.cut_once(msg, PAIR_ERROR);
    }
    let reason = msg
        .get("reason")
        .and_then(Value::as_str)
        .and_then(|reason| REASONS.iter().position(|known| *known == reason))
        .and_then(|index| u8::try_from(index).ok())
        .unwrap_or(0);
    let count = count(msg, "count").map_or(0, |n| u32::try_from(n).unwrap_or(u32::MAX));
    let window = count_window(msg);
    let key = key(CardKind::AgentPair, peer);
    let base = listed(key, at, BASE);
    if let Some(index) = state.card_at(key)
        && let Some(card) = state.cards.get_mut(index)
        && let Facts::AgentPair { resumed: false, .. } = card.facts
    {
        if let Facts::AgentPair { reason: r, count: c, window: w, error: e, .. } = &mut card.facts {
            (*r, *c, *w, *e) = (reason, count, window, error);
        }
        card.listed.retain(|listed| listed.mark != BASE);
        card.listed.insert(0, base);
        state.patch_card(index, false, out);
        return Ok(());
    }
    // A pause after a resume: the new card takes what the old one still held.
    let mut carried = Vec::new();
    let mut held = 0;
    if let Some(index) = state.card_at(key)
        && let Some(card) = state.cards.get_mut(index)
    {
        carried = card.listed.iter().filter(|listed| listed.mark == HELD).copied().collect();
        if !carried.is_empty() {
            card.listed.retain(|listed| listed.mark != HELD);
            if let Facts::AgentPair { held, .. } = &mut card.facts {
                *held = 0;
            }
            held = u32::try_from(carried.len()).unwrap_or(u32::MAX);
            state.patch_card(index, true, out);
        } else {
            state.cards.remove(index);
        }
    }
    let mut list = vec![base];
    list.extend(carried);
    let facts = Facts::AgentPair {
        reason,
        count,
        window,
        error,
        released: 0,
        dropped: 0,
        held,
        resumed: false,
    };
    state.open_card(CardKind::AgentPair, key, facts, list, false, out)
}
fn count_window(msg: &Map<String, Value>) -> Option<u64> {
    count(msg, "windowSecs")
}
/// `agent_pair_held`: a message held from the peer, listed once by its prompt id.
fn held(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let (Some(from), Some(prompt)) = (str_of(msg, "from"), str_of(msg, "promptId")) else {
        state.refused();
        return Ok(());
    };
    let Some(index) = state.card_at(key(CardKind::AgentPair, from)) else {
        return state.orphan("agent_pair_held", at, out);
    };
    let item = prompt_hash(prompt);
    let Some(card) = state.cards.get_mut(index) else { return Ok(()) };
    if card.listed.iter().any(|listed| listed.mark == HELD && listed.key == item) {
        return Ok(());
    }
    if let Facts::AgentPair { held, .. } = &mut card.facts {
        *held = held.saturating_add(1);
    }
    // Past the list the view shows, the item counts in `held` and is not listed.
    if card.listed.iter().filter(|listed| listed.mark == HELD).count() < MAX_HELD {
        card.listed.push(listed(item, at, HELD));
    }
    state.patch_card(index, false, out);
    Ok(())
}
/// `agent_pair_released` and `agent_pair_dropped`: the item leaves the list, and is counted.
fn settle_held(
    state: &mut State,
    msg: &Map<String, Value>,
    released: bool,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let Some(peer) = str_of(msg, "peer") else {
        state.refused();
        return Ok(());
    };
    let kind = if released { "agent_pair_released" } else { "agent_pair_dropped" };
    let Some(index) = state.card_at(key(CardKind::AgentPair, peer)) else {
        return state.orphan(kind, at, out);
    };
    let item = msg.get("promptId").and_then(Value::as_str).map(prompt_hash);
    let Some(card) = state.cards.get_mut(index) else { return Ok(()) };
    let before = card.listed.len();
    card.listed.retain(|listed| !(listed.mark == HELD && Some(listed.key) == item));
    let left = before != card.listed.len();
    if let Facts::AgentPair { released: r, dropped: d, held, .. } = &mut card.facts {
        // The count rises even when the item was not listed, as the view counts it.
        if released {
            *r = r.saturating_add(1);
        } else {
            *d = d.saturating_add(1);
        }
        if left {
            *held = held.saturating_sub(1);
        }
    }
    let done = matches!(card.facts, Facts::AgentPair { resumed: true, .. })
        && !card.listed.iter().any(|listed| listed.mark == HELD);
    state.patch_card(index, done, out);
    Ok(())
}
/// `agent_pair_resumed`: the pair goes on; a card with nothing held is decided.
fn resumed(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let Some(peer) = str_of(msg, "peer") else {
        state.refused();
        return Ok(());
    };
    let Some(index) = state.card_at(key(CardKind::AgentPair, peer)) else {
        return state.orphan("agent_pair_resumed", at, out);
    };
    let Some(card) = state.cards.get_mut(index) else { return Ok(()) };
    if let Facts::AgentPair { resumed, .. } = &mut card.facts {
        if *resumed {
            return Ok(());
        }
        *resumed = true;
    }
    // Kept while it holds items: their release or drop still patches it.
    let done = !card.listed.iter().any(|listed| listed.mark == HELD);
    state.patch_card(index, done, out);
    Ok(())
}

/// `memory_offer`: facts to remember, as `memoryOfferFromRecord` reads them.
fn memory_offer(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let (Some(offer), Some(_file)) = (str_of(msg, "offerId"), trimmed(msg, "file")) else {
        state.refused();
        return Ok(());
    };
    let mut facts: Vec<u64> = Vec::new();
    for fact in msg.get("facts").and_then(Value::as_array).into_iter().flatten() {
        if let Some(fact) = fact.as_str().map(str::trim).filter(|fact| !fact.is_empty()) {
            let hash = prompt_hash(fact);
            if !facts.contains(&hash) && facts.len() < MAX_FACTS {
                facts.push(hash);
            }
        }
    }
    if facts.is_empty() {
        state.refused();
        return Ok(());
    }
    state.cut_once(msg, FILE);
    let key = key(CardKind::Memory, offer);
    // The same offer again replaces its card, as the view's row is set again.
    if let Some(index) = state.card_at(key) {
        state.cards.remove(index);
    }
    let created = msg.get("created") == Some(&Value::Bool(true));
    let facts = Facts::Memory { facts, accepted: 0, dismissed: 0, created };
    state.open_card(CardKind::Memory, key, facts, vec![listed(key, at, BASE)], false, out)
}
/// `memory_resolved`: which facts were accepted and dismissed; each settles once, accepted first.
fn memory_resolved(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let Some(offer) = str_of(msg, "offerId") else {
        state.refused();
        return Ok(());
    };
    let Some(index) = state.card_at(key(CardKind::Memory, offer)) else {
        return state.orphan("memory_resolved", at, out);
    };
    let Some(card) = state.cards.get_mut(index) else { return Ok(()) };
    let Facts::Memory { facts, accepted, dismissed, .. } = &mut card.facts else { return Ok(()) };
    let mut changed = false;
    for (list, mask) in [("accepted", 0usize), ("dismissed", 1)] {
        for named in msg.get(list).and_then(Value::as_array).into_iter().flatten() {
            let Some(named) = named.as_str() else { continue };
            let hash = prompt_hash(named);
            for (bit, fact) in facts.iter().enumerate() {
                let bit = 1u8 << u32::try_from(bit).unwrap_or(7).min(7);
                if *fact == hash && (*accepted | *dismissed) & bit == 0 {
                    if mask == 0 {
                        *accepted |= bit;
                    } else {
                        *dismissed |= bit;
                    }
                    changed = true;
                }
            }
        }
    }
    if !changed {
        return Ok(());
    }
    let all = facts.len();
    let settled = (*accepted | *dismissed).count_ones();
    let done = usize::try_from(settled).is_ok_and(|settled| settled >= all);
    state.patch_card(index, done, out);
    Ok(())
}

/// `coach_offer`: the card in its offered state; the page asks for the rewrite once, under its
/// own settings, and draws nothing until `coach` patches it (decision 253, a).
fn coach_offer(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let Some(coach) = str_of(msg, "coachId") else {
        state.refused();
        return Ok(());
    };
    let key = key(CardKind::Coach, coach);
    if state.card_at(key).is_some() {
        return Ok(());
    }
    state.cut_once(msg, COACH_ID);
    let facts = Facts::Coach { corrections: None };
    state.open_card(CardKind::Coach, key, facts, vec![listed(key, at, BASE)], false, out)
}
/// `coach`: the rewrite, onto its offered card, or a card of its own whole.
fn coach(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let coach = str_of(msg, "coachId");
    let rewrite =
        msg.get("rewrite").and_then(Value::as_str).is_some_and(|text| !text.trim().is_empty());
    let (Some(coach), true) = (coach, rewrite) else {
        state.refused();
        return Ok(());
    };
    let corrections = count(msg, "corrections").map_or(0, |n| u32::try_from(n).unwrap_or(u32::MAX));
    let key = key(CardKind::Coach, coach);
    if let Some(index) = state.card_at(key)
        && let Some(card) = state.cards.get_mut(index)
    {
        card.facts = Facts::Coach { corrections: Some(corrections) };
        card.listed.push(listed(key, at, DECISION));
        state.patch_card(index, true, out);
        return Ok(());
    }
    state.cut_once(msg, COACH_ID);
    let facts = Facts::Coach { corrections: Some(corrections) };
    state.open_card(CardKind::Coach, key, facts, vec![listed(key, at, BASE)], true, out)
}

/// The preset approval's key, `[preset, digest]`, by the `text()` rule.
fn preset_key(msg: &Map<String, Value>) -> Option<u64> {
    let preset = preset_text(msg.get("preset"))?;
    let digest = preset_text(msg.get("digest"))?;
    Some(key(CardKind::Preset, &format!("{preset}\0{digest}")))
}
/// `preset_approval_request`: a card per preset and digest, open until decided; a request to an
/// open card is its newest ask.
fn preset_request(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let complete = ["harness", "policy"].iter().all(|key| preset_text(msg.get(*key)).is_some());
    let (Some(key), true) = (preset_key(msg), complete) else {
        state.refused();
        return Ok(());
    };
    state.cut_once(msg, PRESET);
    if let Some(index) = state.card_at(key)
        && let Some(card) = state.cards.get_mut(index)
    {
        card.listed = vec![listed(key, at, BASE)];
        if let Facts::Preset { requests, .. } = &mut card.facts {
            *requests = requests.saturating_add(1);
        }
        state.patch_card(index, false, out);
        return Ok(());
    }
    let facts = Facts::Preset { requests: 1, outcome: None };
    state.open_card(CardKind::Preset, key, facts, vec![listed(key, at, BASE)], false, out)
}
/// `preset_approval_decision`: the open card's outcome; the next request opens a new card.
fn preset_decision(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let outcome = msg
        .get("outcome")
        .and_then(Value::as_str)
        .and_then(|word| PRESET_OUTCOMES.iter().position(|known| *known == word))
        .and_then(|index| u8::try_from(index).ok());
    let (Some(key), Some(outcome)) = (preset_key(msg), outcome) else {
        state.refused();
        return Ok(());
    };
    let Some(index) = state.card_at(key) else {
        return state.orphan("preset_approval_decision", at, out);
    };
    if let Some(card) = state.cards.get_mut(index)
        && let Facts::Preset { outcome: o, .. } = &mut card.facts
    {
        *o = Some(outcome);
    }
    state.patch_card(index, true, out);
    Ok(())
}

/// `session_offer`: a suggested task, on its group's card or one of its own; sent again, it moves
/// to the end.
fn session_offer(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let required = ["title", "prompt", "cwd"].iter().all(|key| str_of(msg, key).is_some());
    let (Some(offer), true) = (str_of(msg, "offerId"), required) else {
        state.refused();
        return Ok(());
    };
    let item = prompt_hash(offer);
    let group = str_of(msg, "groupId");
    let key = match group {
        Some(group) => key(CardKind::Offers, &format!("group\0{group}")),
        None => key(CardKind::Offers, &format!("offer\0{offer}")),
    };
    let entry = listed(item, at, UNDECIDED);
    if let Some(index) = state.card_at(key)
        && let Some(card) = state.cards.get_mut(index)
    {
        card.listed.retain(|listed| listed.key != item);
        while card.listed.iter().filter(|listed| listed.mark != DECISION).count() >= MAX_OFFERS {
            let Some(oldest) =
                card.listed.iter().find(|listed| listed.mark != DECISION).map(|l| l.key)
            else {
                break;
            };
            card.listed.retain(|listed| listed.key != oldest);
            state.evicted_cards = state.evicted_cards.saturating_add(1);
        }
        card.listed.push(entry);
        state.patch_card(index, false, out);
        return Ok(());
    }
    let facts = Facts::Offers { group: group.is_some() };
    state.open_card(CardKind::Offers, key, facts, vec![entry], false, out)
}
/// `session_offer_decision`: the offer's outcome, and the decision itself listed when it names the
/// chat it started.
fn offer_decision(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let outcome = msg
        .get("outcome")
        .and_then(Value::as_str)
        .and_then(|word| OUTCOMES.iter().position(|known| *known == word))
        .and_then(|index| u8::try_from(index.saturating_add(1)).ok());
    let (Some(offer), Some(outcome)) = (str_of(msg, "offerId"), outcome) else {
        state.refused();
        return Ok(());
    };
    let item = prompt_hash(offer);
    let found = state.cards.iter().position(|card| {
        card.kind == CardKind::Offers
            && card.listed.iter().any(|listed| listed.mark != DECISION && listed.key == item)
    });
    let Some(index) = found else {
        return state.orphan("session_offer_decision", at, out);
    };
    let Some(card) = state.cards.get_mut(index) else { return Ok(()) };
    for listed in &mut card.listed {
        if listed.mark != DECISION && listed.key == item {
            listed.mark = outcome;
        }
    }
    card.listed.retain(|listed| !(listed.mark == DECISION && listed.key == item));
    if msg.get("childSessionId").is_some_and(Value::is_string) {
        card.listed.push(listed(item, at, DECISION));
    }
    // A single offer is decided with its outcome; a group's card stays for its later offers.
    let single = matches!(card.facts, Facts::Offers { group: false });
    state.patch_card(index, single, out);
    Ok(())
}

/// `plan_build`: a build started in worktrees (`started`), and the one kept (`kept`).
fn plan_build(
    state: &mut State,
    msg: &Map<String, Value>,
    at: At<'_>,
    out: &mut input::Output<'_>,
) -> Result<(), Error> {
    let Some(build) = trimmed(msg, "buildId") else {
        state.refused();
        return Ok(());
    };
    let key = key(CardKind::PlanBuild, build);
    match msg.get("event").and_then(Value::as_str) {
        Some("started") => {
            let target = msg.get("target").and_then(Value::as_str);
            let builds = msg.get("builds").and_then(Value::as_array);
            let started = builds.is_some_and(|builds| {
                builds.iter().any(|build| {
                    build
                        .get("sessionId")
                        .and_then(Value::as_str)
                        .is_some_and(|id| !id.trim().is_empty())
                })
            });
            if !matches!(target, Some("compare" | "worktree")) || !started {
                state.refused();
                return Ok(());
            }
            if let Some(index) = state.card_at(key)
                && let Some(card) = state.cards.get_mut(index)
            {
                card.listed.retain(|listed| listed.mark != BASE);
                card.listed.insert(0, listed(key, at, BASE));
                state.patch_card(index, false, out);
                return Ok(());
            }
            let facts = Facts::PlanBuild { kept: false };
            state.open_card(
                CardKind::PlanBuild,
                key,
                facts,
                vec![listed(key, at, BASE)],
                false,
                out,
            )
        }
        Some("kept") => {
            let Some(index) = state.card_at(key) else {
                return state.orphan("plan_build", at, out);
            };
            if let Some(card) = state.cards.get_mut(index) {
                card.facts = Facts::PlanBuild { kept: true };
                card.listed.retain(|listed| listed.mark != DECISION);
                card.listed.push(listed(key, at, DECISION));
            }
            state.patch_card(index, true, out);
            Ok(())
        }
        _ => {
            state.refused();
            Ok(())
        }
    }
}
