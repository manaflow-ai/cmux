//! Tells apart Macs that share a name ("Aziz's MacBook Pro" twice): only Macs whose name
//! collides with another in the same list get a tag, the end of the Mac's device id ("3F2A"),
//! at least four characters and longer only when two colliding ids end alike. Swift's
//! `MacNameDisambiguation` keeps the display strings and dates; this is its rule.

use std::collections::{HashMap, HashSet};

/// One Mac in the list: its device id and display name.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacNameInput {
    pub id: String,
    pub name: String,
}

/// A colliding Mac's tag.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacNameTagged {
    pub id: String,
    pub tag: String,
}

/// The tags of the Macs in `macs` whose name collides with another's, in list order. Names
/// that differ only by case or surrounding spaces collide; the same id listed twice counts once.
#[uniffi::export]
pub fn mac_name_tags(macs: Vec<MacNameInput>) -> Vec<MacNameTagged> {
    let mut seen = HashSet::new();
    let unique: Vec<MacNameInput> = macs.into_iter().filter(|mac| seen.insert(mac.id.clone())).collect();
    let mut groups: HashMap<String, Vec<String>> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for mac in unique {
        let key = name_key(&mac.name);
        let group = groups.entry(key.clone()).or_default();
        if group.is_empty() {
            order.push(key);
        }
        group.push(mac.id);
    }
    let mut tags = Vec::new();
    for key in order {
        let ids = &groups[&key];
        if ids.len() < 2 {
            continue;
        }
        for (id, tag) in ids.iter().zip(id_suffixes(ids)) {
            tags.push(MacNameTagged { id: id.clone(), tag });
        }
    }
    tags
}

/// Names that differ only by case or surrounding spaces read the same.
fn name_key(name: &str) -> String {
    name.trim().to_lowercase()
}

/// The shortest id endings (at least four characters, letters and digits only, upper case)
/// that differ across `ids`; an id too short for that is used whole.
fn id_suffixes(ids: &[String]) -> Vec<String> {
    let cleaned: Vec<Vec<char>> = ids
        .iter()
        .map(|id| {
            let upper = id.to_uppercase();
            let chars: Vec<char> = upper.chars().filter(|c| c.is_alphanumeric()).collect();
            if chars.is_empty() { upper.chars().collect() } else { chars }
        })
        .collect();
    let suffix = |chars: &Vec<char>, length: usize| -> String {
        chars[chars.len().saturating_sub(length)..].iter().collect()
    };
    let longest = cleaned.iter().map(Vec::len).max().unwrap_or(0);
    let mut length = 4;
    while length < longest {
        let tags: Vec<String> = cleaned.iter().map(|chars| suffix(chars, length)).collect();
        if tags.iter().collect::<HashSet<_>>().len() == tags.len() {
            return tags;
        }
        length += 1;
    }
    cleaned.iter().map(|chars| suffix(chars, length.max(4))).collect()
}

#[cfg(test)]
#[path = "mac_name_tags_tests.rs"]
mod tests;
