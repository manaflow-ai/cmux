//! Local attribution only; no inference events are submitted to a server.
use super::*;

/// Who paid for inference, derived without retaining the URL or credentials.
pub fn payer_provider(harness: &str, base_url: Option<&str>) -> (&'static str, &'static str) {
    let url = base_url.and_then(|s| url::Url::parse(s).ok());
    let host = url.as_ref().and_then(url::Url::host_str).unwrap_or("");
    let declared_proxy = url.as_ref().is_some_and(|actual| {
        crate::harness_gate::TEAM_SUBROUTER_URLS.iter().any(|base| {
            url::Url::parse(base).is_ok_and(|declared| actual.origin() == declared.origin())
        })
    });
    let platform = declared_proxy
        || matches!(host, "coderouter.dev" | "coderouter.cmux.internal")
        || host == "cmux.dev"
        || host.ends_with(".cmux.dev")
        || host == "cmux.com"
        || host.ends_with(".cmux.com");
    if platform
        || matches!(
            harness,
            "cmux" | "cmux-router" | "claude-cr" | "codex-cr" | "claude-sr" | "claude-sr2"
        )
    {
        return ("platform", "cmux-router");
    }
    if matches!(harness, "native" | "api") && base_url.is_none_or(str::is_empty) {
        return ("unknown", "unknown");
    }
    let provider = match host {
        "api.anthropic.com" => "anthropic",
        "api.openai.com" => "openai",
        "api.deepinfra.com" => "deepinfra",
        _ if harness.starts_with("claude") => "anthropic",
        _ if harness.starts_with("codex") => "openai",
        _ => "unknown",
    };
    ("own", provider)
}

/// A missing account or a local conversation label cannot identify a payer.
fn account_id(person: Option<&str>) -> Option<&str> {
    person.map(str::trim).filter(|id| {
        !id.is_empty()
            && *id != "unknown"
            && *id != cmux_chief::rules::USER_LOCAL
            && !id.starts_with("remote_")
            && !id.starts_with("agent_")
    })
}

/// Only ids and route labels cross this boundary, never auth or URL fields.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub(super) struct Attribution {
    pub person: Option<String>,
    pub team: Option<String>,
    pub chief: Option<String>,
    pub harness: Option<String>,
    pub payer: Option<String>,
    pub provider: Option<String>,
    pub machine: Option<String>,
}

impl Attribution {
    pub fn event(v: &Value) -> Self {
        let harness = opt_s(v, "harness");
        let route = harness
            .as_deref()
            .map(|h| payer_provider(h, v["base_url"].as_str()));
        Self {
            person: v
                .get("person")
                .map(|person| account_id(person.as_str()).unwrap_or("unknown").to_owned()),
            team: opt_s(v, "team"),
            chief: opt_s(v, "chief"),
            payer: opt_s(v, "payer").or_else(|| route.map(|r| r.0.into())),
            provider: opt_s(v, "provider").or_else(|| route.map(|r| r.1.into())),
            machine: opt_s(v, "machine").or_else(|| opt_s(v, "peer")),
            harness,
        }
    }

    pub fn over(mut self, fallback: &Self) -> Self {
        macro_rules! inherit { ($($field:ident),*) => { $(self.$field = self.$field.or_else(|| fallback.$field.clone());)* }; }
        inherit!(person, team, chief, harness, payer, provider, machine);
        self
    }

    pub fn apply(&self, line: &mut Line) {
        line.person = Some(
            account_id(self.person.as_deref())
                .unwrap_or("unknown")
                .to_owned(),
        );
        line.team.clone_from(&self.team);
        line.chief.clone_from(&self.chief);
        line.harness.clone_from(&self.harness);
        line.payer.clone_from(&self.payer);
        line.provider.clone_from(&self.provider);
        line.machine.clone_from(&self.machine);
    }
}

#[derive(Default)]
pub(super) struct Meter {
    owner: Attribution,
    active: Attribution,
    native_route: Attribution,
    contexts: HashMap<String, Attribution>,
    people: HashMap<String, String>,
}

impl Meter {
    pub fn seed(&mut self, line: &Line) {
        if let Some(id) = &line.agent {
            if self.contexts.contains_key(&format!("sub:{id}")) {
                return;
            }
            self.remember(
                format!("sub:{id}"),
                Attribution {
                    // A legacy row has no evidence of its initiator. Keep that
                    // unresolved across restarts instead of inheriting today's owner.
                    person: Some(
                        account_id(line.person.as_deref())
                            .unwrap_or("unknown")
                            .to_owned(),
                    ),
                    team: line.team.clone(),
                    chief: line.chief.clone(),
                    harness: line.harness.clone(),
                    payer: line.payer.clone(),
                    provider: line.provider.clone(),
                    machine: line.machine.clone(),
                },
            );
        }
    }

    fn remember(&mut self, key: String, context: Attribution) {
        if self.contexts.len() >= MAX_REMEMBERED && !self.contexts.contains_key(&key) {
            self.contexts.clear();
        }
        self.contexts.insert(key, context);
    }

    pub fn observe(&mut self, ev: &str, v: &Value) {
        match ev {
            "usage.identity" => self.owner = Attribution::event(v),
            "usage.native_route" => self.native_route = Attribution::event(v),
            "usage.message" => {
                if let Some(id) = opt_s(v, "id") {
                    let person = account_id(v["person"].as_str())
                        .unwrap_or("unknown")
                        .to_owned();
                    Fold::remember(&mut self.people, id, person);
                }
            }
            "turn.start" => {
                let mut context = self.event(v).over(&self.owner);
                if let Some(first) = v["message_keys"].as_array().and_then(|keys| keys.first()) {
                    context.person = Some(
                        first
                            .as_str()
                            .and_then(|id| self.people.get(id))
                            .cloned()
                            .unwrap_or_else(|| "unknown".to_owned()),
                    );
                }
                self.active = context.clone();
                if let Some(key) = opt_s(v, "turn") {
                    self.remember(format!("turn:{key}"), context);
                }
            }
            "spawn" => {
                if let Some(ids) = v["ids"].as_array() {
                    for (index, id) in ids
                        .iter()
                        .enumerate()
                        .filter_map(|(i, id)| Some((i, id.as_str()?)))
                    {
                        // A spawn belongs to the turn that requested it, even if
                        // the queued subagent starts during another person's turn.
                        let mut context = Attribution::event(v).over(&Attribution {
                            harness: None,
                            payer: None,
                            provider: None,
                            ..self.active.clone()
                        });
                        context.machine = v["peers"]
                            .get(index)
                            .and_then(Value::as_str)
                            .map(str::to_owned)
                            .or_else(|| Some("here".into()));
                        self.remember(format!("sub:{id}"), context);
                    }
                }
            }
            "subagent.start" => {
                if let Some(id) = opt_s(v, "id") {
                    let key = format!("sub:{id}");
                    let fallback = self.contexts.get(&key).unwrap_or(&self.owner);
                    let mut context = Attribution::event(v).over(fallback);
                    if context.machine.is_none() {
                        context.machine = Some("here".into());
                    }
                    self.remember(key, context);
                }
            }
            _ => {}
        }
    }

    fn event(&self, v: &Value) -> Attribution {
        let mut context = Attribution::event(v);
        if matches!(context.harness.as_deref(), Some("native" | "api")) && v["base_url"].is_null() {
            context.payer = self.native_route.payer.clone().or(context.payer);
            context.provider = self.native_route.provider.clone().or(context.provider);
        }
        context
    }

    pub fn apply(&mut self, ev: &str, v: &Value, line: &mut Line) {
        let key = match ev {
            "turn.end" => Some(format!("turn:{}", line.key)),
            "subagent.answer" => line.agent.as_ref().map(|id| format!("sub:{id}")),
            _ => None,
        };
        let current = self.event(v);
        let context = key.as_ref().and_then(|k| self.contexts.get(k));
        // End events often omit the route; preserve the route selected at start.
        let mut attribution = context
            .cloned()
            .unwrap_or_default()
            .over(&current)
            .over(&self.owner);
        attribution.person = current.person.or(attribution.person);
        attribution.apply(line);
        if ev == "turn.end"
            && let Some(key) = key
        {
            self.contexts.remove(&key);
        }
    }
}

/// A local export row compatible with the router's usage_events vocabulary.
/// `input_tokens` includes cache reads and writes; cached reads are also
/// reported as its subset, as in the router. A legacy subagent's timestamp disambiguates repeated prompts.
pub fn export_row(chief: &Chief, line: &Line) -> Value {
    let legacy_scope = if chief.id == "default" {
        crate::paths::home_id(Path::new(&chief.home))
    } else {
        chief.id.clone()
    };
    let id = line.chief.as_deref().unwrap_or(&legacy_scope);
    let (payer, provider) = payer_provider(line.harness.as_deref().unwrap_or(""), None);
    let key = if line.kind == "compactor"
        || (line.kind == "subagent" && line.agent.as_deref() == Some(line.key.as_str()))
    {
        format!("{}:{}", line.key, line.ts)
    } else {
        line.key.clone()
    };
    let person = account_id(line.person.as_deref());
    let payer = line.payer.as_deref().unwrap_or(payer);
    json!({
        "event_time": chrono::DateTime::from_timestamp_millis(line.ts.min(i64::MAX as u64) as i64).map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)),
        "stack_user_id": person.unwrap_or("unknown"), "team_id": line.team,
        "billable": person.is_some() && payer == "platform",
        "provider": line.provider.as_deref().unwrap_or(provider), "agent": line.harness,
        "model": line.model, "input_tokens": line.input.saturating_add(line.cache_write).saturating_add(line.cache_read),
        "cached_input_tokens": line.cache_read, "output_tokens": line.output,
        "total_tokens": line.tokens(), "api_equivalent_usd": line.usd,
        "request_id": format!("chief:{id}:{}:{key}", line.kind),
        "status": line.status, "payer": payer,
        "kind": line.kind, "machine": line.machine,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn payer_is_pure_and_does_not_match_url_substrings() {
        assert_eq!(payer_provider("claude", None), ("own", "anthropic"));
        assert_eq!(payer_provider("cmux", None), ("platform", "cmux-router"));
        assert_eq!(
            payer_provider("claude-cr", None),
            ("platform", "cmux-router")
        );
        assert_eq!(
            payer_provider("native", Some(optchat_host::DEFAULT_BASE_URL)),
            ("platform", "cmux-router")
        );
        assert_eq!(
            payer_provider("native", Some("https://coderouter.dev/v1")),
            ("platform", "cmux-router")
        );
        assert_eq!(
            payer_provider("native", Some("https://evil.test/?host=coderouter.dev")),
            ("own", "unknown")
        );
    }
}
