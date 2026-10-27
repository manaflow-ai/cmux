//! Each chat's agent mark (`brand` on a chat value): acpmux resolves it once
//! per chat, so the app and the pages draw the mark with no per-chat lookup.
//! The table is generated from design/agent-icons/manifest.json
//! (scripts/agent-icons/generate.py, `--check` in agent-brands.yml); the
//! resolution order is the catalog's (`AgentBrandCatalog.brand(for:)`).

mod table;

use std::collections::HashMap;
use std::sync::OnceLock;

use cmux_chat_index::AdapterKind;

/// The brand of a harness's chats, resolved once per harness (not once per chat).
pub fn harness_brand(harness: AdapterKind) -> Option<&'static str> {
    static BRANDS: OnceLock<HashMap<AdapterKind, Option<&'static str>>> = OnceLock::new();
    BRANDS
        .get_or_init(|| AdapterKind::ALL.iter().map(|kind| (*kind, brand_for(kind.id()))).collect())
        .get(&harness)
        .copied()
        .flatten()
}

/// The brand id for an agent, harness, alias, binary path or provider id, or
/// None when it has no mark. Matching ignores case and surrounding space,
/// then tries, in order: the whole id; the part after the last `:`; the last
/// path component; the first word; the first `-`, `_` or `.` separated part.
/// The first candidate the table knows decides, including ids known to have
/// no mark.
pub fn brand_for(agent: &str) -> Option<&'static str> {
    candidates(agent).iter().find_map(|candidate| {
        table::LOOKUP
            .binary_search_by(|(id, _)| (*id).cmp(candidate.as_str()))
            .ok()
            .map(|index| table::LOOKUP[index].1)
    })?
}

/// The brand of exactly `id` (ignoring case and surrounding space), with no
/// part-of-the-id fallback: what a profile's `icon = "goose"` names.
pub fn exact(id: &str) -> Option<&'static str> {
    let id = id.trim().to_lowercase();
    table::LOOKUP
        .binary_search_by(|(known, _)| (*known).cmp(id.as_str()))
        .ok()
        .and_then(|index| table::LOOKUP[index].1)
}

fn candidates(raw: &str) -> Vec<String> {
    let id = raw.trim().to_lowercase();
    if id.is_empty() {
        return Vec::new();
    }
    let mut out = vec![id.clone()];
    add(&mut out, id.split(':').rfind(|part| !part.is_empty()));
    add(&mut out, id.split('/').rfind(|part| !part.is_empty()));
    let word = out.last().and_then(|last| last.split_whitespace().next()).map(str::to_owned);
    add(&mut out, word.as_deref());
    let part =
        word.as_deref().and_then(|word| word.split(['-', '_', '.']).find(|part| !part.is_empty()));
    add(&mut out, part);
    out
}

fn add(out: &mut Vec<String>, value: Option<&str>) {
    if let Some(value) = value.filter(|v| !v.is_empty())
        && !out.iter().any(|known| known == value)
    {
        out.push(value.to_owned());
    }
}
