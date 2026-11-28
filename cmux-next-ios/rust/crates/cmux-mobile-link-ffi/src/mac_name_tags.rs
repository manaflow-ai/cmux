//! Same-name Mac tags (Swift's `MacNameDisambiguation`): two Macs named "Aziz's MacBook Pro"
//! read "Aziz's MacBook Pro 3F2A" and "Aziz's MacBook Pro 91C7" in Settings → Devices, the
//! Workspaces filter and the remove confirmation. Only a Mac whose name collides with another
//! in the list gets a tag; a unique name reads as before.
//!
//! The tag is the end of the Mac's device id, the one stable identifier every list has (the
//! team's Macs, presence frames and `GET /v1/me/devices`), so the same Mac carries the same tag
//! on every surface. A tag is at least four characters, and longer only when two colliding ids
//! end alike. Swift keeps the copy ("Added Oct 13") and the date formatting; these are the rules.

use std::collections::{HashMap, HashSet};

/// One Mac in the list: its device id and display name.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacNameEntry {
    pub id: String,
    pub name: String,
}

/// The shortest tag length tried.
const MIN_TAG: usize = 4;

/// Tag by device id, for the Macs whose name collides with another's. The same id listed twice
/// (the same Mac in two lists) counts once; names that differ only by case or surrounding
/// whitespace read the same.
#[uniffi::export]
pub fn mac_name_tags(macs: Vec<MacNameEntry>) -> HashMap<String, String> {
    let mut seen = HashSet::new();
    let mut groups: Vec<(String, Vec<String>)> = Vec::new();
    for mac in macs {
        if !seen.insert(mac.id.clone()) {
            continue;
        }
        let key = name_key(&mac.name);
        match groups.iter_mut().find(|(k, _)| *k == key) {
            Some((_, ids)) => ids.push(mac.id),
            None => groups.push((key, vec![mac.id])),
        }
    }
    let mut tags = HashMap::new();
    for (_, ids) in groups.into_iter().filter(|(_, ids)| ids.len() > 1) {
        let suffixes = id_suffixes(&ids);
        tags.extend(ids.into_iter().zip(suffixes));
    }
    tags
}

/// The name as collisions compare it.
fn name_key(name: &str) -> String {
    name.trim().to_lowercase()
}

/// The shortest id endings (at least four characters, letters and digits only, uppercased) that
/// differ across `ids`; an id too short for that is used whole.
fn id_suffixes(ids: &[String]) -> Vec<String> {
    let cleaned: Vec<Vec<char>> = ids
        .iter()
        .map(|id| {
            let upper = id.to_uppercase();
            let chars: Vec<char> = upper.chars().filter(|c| c.is_alphanumeric()).collect();
            if chars.is_empty() { upper.chars().collect() } else { chars }
        })
        .collect();
    let longest = cleaned.iter().map(Vec::len).max().unwrap_or(0);
    let mut length = MIN_TAG;
    while length < longest {
        let tags: Vec<String> = cleaned.iter().map(|c| suffix(c, length)).collect();
        if tags.iter().collect::<HashSet<_>>().len() == tags.len() {
            return tags;
        }
        length += 1;
    }
    cleaned.iter().map(|c| suffix(c, length.max(MIN_TAG))).collect()
}

fn suffix(chars: &[char], length: usize) -> String {
    chars[chars.len().saturating_sub(length)..].iter().collect()
}

#[cfg(test)]
#[path = "mac_name_tags_tests.rs"]
mod tests;
