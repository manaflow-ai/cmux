use super::*;

fn askers() -> Vec<Asker> {
    let mut out = vec![Asker::Person];
    for own_chat in [true, false] {
        for auto_cloud in [true, false] {
            for enabled in [true, false] {
                out.push(Asker::Agent { own_chat, auto_cloud, enabled });
            }
        }
    }
    out
}

/// Every from × to × asker (person; agent × own chat × AutoCloud setting × kill switch).
#[test]
fn chat_move_consent_matrix() {
    let mut cells = 0;
    for from in Place::ALL {
        for to in Place::ALL {
            for asker in askers() {
                cells += 1;
                let c = consent(from, to, asker);
                let cell = format!("{from:?} -> {to:?} by {asker:?}: {c:?}");
                match asker {
                    Asker::Person => {
                        let want = if from == to { Consent::Already } else { Consent::Go };
                        assert_eq!(c, want, "{cell}");
                    }
                    Asker::Agent { own_chat: false, .. } => {
                        assert!(matches!(c, Consent::Refused(_)), "{cell}");
                    }
                    Asker::Agent { own_chat: true, auto_cloud, enabled } => {
                        if from == to {
                            assert_eq!(c, Consent::Already, "{cell}");
                        } else if to == Place::Local {
                            // Cloud→Local and Auto→Local: home, unless the kill switch is on.
                            assert_eq!(c == Consent::Go, enabled, "{cell}");
                        } else {
                            let go = auto_cloud && enabled;
                            assert_eq!(c == Consent::Go, go, "{cell}");
                            if !go {
                                assert!(matches!(c, Consent::NeedsPerson(_)), "{cell}");
                            }
                        }
                    }
                }
                // A Go lands exactly where it was asked to.
                if c == Consent::Go {
                    assert_eq!(Place::of_row(&to.set_params("s")), to, "{cell}");
                }
                let answer = not_moved("s", from, to, &c);
                if let Consent::NeedsPerson(_) = c {
                    assert_eq!(answer["status"], "needs_person", "{cell}");
                    assert_eq!(answer["command"], format!("cmux chat move s --on {}", to.as_str()));
                }
            }
        }
    }
    assert_eq!(cells, 3 * 3 * 9);
}

#[test]
fn place_round_trips_through_rows_and_words() {
    for p in Place::ALL {
        assert_eq!(Place::parse(p.as_str()), Some(p));
        assert_eq!(Place::of_row(&p.set_params("x")), p);
    }
    assert_eq!(Place::parse("AutoCloud"), Some(Place::Auto));
    assert_eq!(Place::parse("here"), Some(Place::Local));
    assert_eq!(Place::parse("mars"), None);
    assert_eq!(Place::of_row(&serde_json::json!({})), Place::Local);
    assert_eq!(Place::of_row(&serde_json::json!({"auto": true})), Place::Auto);
}

#[test]
fn kill_switch_words() {
    assert!(agent_moves_enabled_by(None));
    assert!(agent_moves_enabled_by(Some("1")));
    assert!(agent_moves_enabled_by(Some("on")));
    for off in ["off", "0", "false", "OFF", " no "] {
        assert!(!agent_moves_enabled_by(Some(off)), "{off}");
    }
}
