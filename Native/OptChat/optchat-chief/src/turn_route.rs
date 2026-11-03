//! Pure, opt-in turn routing. Harnesses and credentials are never selected here.
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Tier {
    Triage,
    Standard,
    Hard,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Family {
    Claude,
    Codex,
    Native,
}

#[derive(Debug, Deserialize)]
struct Model {
    model: String,
    effort: String,
}

#[derive(Debug, Deserialize)]
struct Tiers {
    triage: Model,
    standard: Model,
    hard: Model,
}

#[derive(Debug, Deserialize)]
struct Signals {
    long_chars: usize,
    several_asks: usize,
    ask_separators: Vec<String>,
    judgment: Vec<String>,
    triage: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct Table {
    claude: Tiers,
    codex: Tiers,
    native: Tiers,
    signals: Signals,
}

impl Table {
    pub fn parse(text: &str) -> Result<Self, String> {
        let table: Self = serde_json::from_str(text).map_err(|e| e.to_string())?;
        for tiers in [&table.claude, &table.codex, &table.native] {
            for model in [&tiers.triage, &tiers.standard, &tiers.hard] {
                if model.model.trim().is_empty()
                    || !["low", "medium", "high"].contains(&model.effort.as_str())
                {
                    return Err(
                        "turn routing requires a model and valid effort in every row".into(),
                    );
                }
            }
        }
        let s = &table.signals;
        if s.long_chars == 0
            || s.several_asks < 2
            || [&s.ask_separators, &s.judgment, &s.triage]
                .iter()
                .any(|list| list.is_empty() || list.iter().any(|s| s.trim().is_empty()))
        {
            return Err("turn routing requires nonempty signals and positive thresholds".into());
        }
        Ok(table)
    }
}

/// Malformed bundled data disables routing safely; the table test fails the build.
pub fn table() -> Result<&'static Table, &'static str> {
    static TABLE: OnceLock<Result<Table, String>> = OnceLock::new();
    TABLE
        .get_or_init(|| Table::parse(include_str!("../routing/turn_models.json")))
        .as_ref()
        .map_err(String::as_str)
}

#[derive(Default)]
pub struct TurnSignals<'a> {
    /// Only new human text, never the compacted view, reports or wake notes.
    pub human_text: Vec<&'a str>,
}

#[derive(Clone, Debug, Serialize)]
pub struct RoutePick {
    pub model: String,
    pub effort: String,
    pub tier: Tier,
    pub reasons: Vec<&'static str>,
}

pub fn classify(input: &TurnSignals<'_>) -> (Tier, Vec<&'static str>) {
    match table() {
        Ok(table) => classify_with(input, table),
        Err(_) => (Tier::Standard, vec!["invalid_table"]),
    }
}

fn classify_with(input: &TurnSignals<'_>, table: &Table) -> (Tier, Vec<&'static str>) {
    let s = &table.signals;
    let texts: Vec<String> = input
        .human_text
        .iter()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    if texts.is_empty() {
        return (Tier::Triage, vec!["no_human_text"]);
    }
    let routine = |text: &str| {
        s.triage
            .iter()
            .any(|word| text.trim_matches(|c: char| !c.is_alphanumeric()) == word)
    };
    if texts.iter().all(|text| routine(text)) {
        return (Tier::Triage, vec!["ack_or_status"]);
    }
    let mut reasons = Vec::new();
    if texts.iter().map(|s| s.chars().count()).sum::<usize>() >= s.long_chars {
        reasons.push("long_message");
    }
    let asks = texts
        .iter()
        .map(|text| {
            1 + s
                .ask_separators
                .iter()
                .map(|sep| text.matches(sep.as_str()).count())
                .sum::<usize>()
        })
        .sum::<usize>();
    if asks >= s.several_asks {
        reasons.push("several_asks");
    }
    if texts.iter().any(|text| {
        s.judgment.iter().any(|word| {
            text.match_indices(word).any(|(at, _)| {
                !text[..at]
                    .chars()
                    .next_back()
                    .is_some_and(char::is_alphanumeric)
                    && !text[at + word.len()..]
                        .chars()
                        .next()
                        .is_some_and(char::is_alphanumeric)
            })
        })
    }) {
        reasons.push("judgment");
    }
    if reasons.is_empty() {
        (Tier::Standard, vec!["human_message"])
    } else {
        (Tier::Hard, reasons)
    }
}

pub fn pick(tier: Tier, family: Family, table: &Table) -> RoutePick {
    let tiers = match family {
        Family::Claude => &table.claude,
        Family::Codex => &table.codex,
        Family::Native => &table.native,
    };
    let model = match tier {
        Tier::Triage => &tiers.triage,
        Tier::Standard => &tiers.standard,
        Tier::Hard => &tiers.hard,
    };
    RoutePick {
        model: model.model.clone(),
        effort: model.effort.clone(),
        tier,
        reasons: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn complete_table_and_classifier() {
        let table = table().expect("valid bundled table");
        for family in [Family::Claude, Family::Codex, Family::Native] {
            for tier in [Tier::Triage, Tier::Standard, Tier::Hard] {
                assert!(!pick(tier, family, table).model.is_empty());
            }
        }
        for (text, tier) in [
            ("", Tier::Triage),
            ("thanks!", Tier::Triage),
            ("status?", Tier::Triage),
            ("What time is it?", Tier::Standard),
            (
                "review this design and decide between A and B, why",
                Tier::Hard,
            ),
            ("Send A; send B; send C", Tier::Hard),
            ("The plant is green", Tier::Standard),
        ] {
            assert_eq!(
                classify(&TurnSignals {
                    human_text: vec![text]
                })
                .0,
                tier,
                "{text}"
            );
        }
        assert_eq!(
            classify(&TurnSignals {
                human_text: vec![&"x".repeat(800)]
            })
            .0,
            Tier::Hard
        );
        let (tier, _) = classify(&TurnSignals::default());
        assert_eq!(pick(tier, Family::Claude, table).model, "claude-haiku-5-5");
        assert!(Table::parse("{}").is_err());
        let bad = include_str!("../routing/turn_models.json").replace("\"low\"", "\"nope\"");
        assert!(Table::parse(&bad).is_err());
    }
}
