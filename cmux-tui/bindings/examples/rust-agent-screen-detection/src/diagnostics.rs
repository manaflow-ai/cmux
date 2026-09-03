#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use cmux::{TerminalId, TerminalLifecycle, TerminalSnapshot};

    use super::resolve_snapshot;

    fn snapshot(hex: &str, title: &str) -> TerminalSnapshot {
        TerminalSnapshot {
            id: TerminalId::parse(format!("term_{hex}"))
                .expect("test terminal ID has the required shape"),
            tab_ids: Vec::new(),
            title: title.to_string(),
            cwd: None,
            cols: 80,
            rows: 24,
            running: true,
            lifecycle: TerminalLifecycle::Running,
            stream_revision: Some(1),
            exit: None,
            extra: BTreeMap::new(),
        }
    }

    #[test]
    fn live_target_accepts_an_exact_terminal_id() {
        let terminals = vec![snapshot("11111111111111111111111111111111", "build")];
        let selected = resolve_snapshot(&terminals, "term_11111111111111111111111111111111")
            .expect("terminal ID should resolve");
        assert_eq!(selected.title, "build");
    }

    #[test]
    fn live_target_rejects_an_ambiguous_title() {
        let terminals = vec![
            snapshot("11111111111111111111111111111111", "agent"),
            snapshot("22222222222222222222222222222222", "agent"),
        ];
        let error = resolve_snapshot(&terminals, "agent").expect_err("duplicate title must fail");
        assert!(error.contains("more than one terminal"), "{error}");
        assert!(error.contains("term_1111"), "{error}");
        assert!(error.contains("term_2222"), "{error}");
    }
}
