//! `acpmux defaults` and `acpmux preset`.

use super::*;

/// `acpmux defaults [FAMILY [key=value…]] [--clear]`.
pub(crate) async fn defaults(
    client: Arc<Client>,
    family: Option<String>,
    pairs: Vec<String>,
    clear: bool,
    json_out: bool,
) -> Result<()> {
    let mut req = json!({});
    if let Some(f) = &family {
        req["family"] = json!(f);
    }
    if clear {
        if family.is_none() {
            return Err(AppError::usage("--clear needs a family").into());
        }
        req["clear"] = json!(true);
    }
    if !pairs.is_empty() {
        if family.is_none() {
            return Err(AppError::usage(
                "key=value pairs need a family: acpmux defaults claude model=…",
            )
            .into());
        }
        let mut set = serde_json::Map::new();
        let mut env = serde_json::Map::new();
        for pair in &pairs {
            let (k, v) = pair
                .split_once('=')
                .ok_or_else(|| AppError::usage(format!("expected key=value, got {pair:?}")))?;
            match k {
                "model" | "effort" | "policy" => {
                    set.insert(k.into(), if v.is_empty() { Value::Null } else { json!(v) });
                }
                "prefer" => {
                    set.insert(
                        k.into(),
                        if v.is_empty() {
                            Value::Null
                        } else {
                            json!(
                                v.split(',')
                                    .map(str::trim)
                                    .filter(|s| !s.is_empty())
                                    .collect::<Vec<_>>()
                            )
                        },
                    );
                }
                _ if k.starts_with("env.") => {
                    env.insert(k[4..].into(), json!(v));
                }
                _ => {
                    return Err(AppError::usage(format!(
                        "unknown key {k:?}; use model, effort, policy, prefer, env.KEY"
                    ))
                    .into());
                }
            }
        }
        if !env.is_empty() {
            set.insert("env".into(), Value::Object(env));
        }
        req["set"] = Value::Object(set);
    }
    let v = client.request(method::MUX_DEFAULTS, req).await?;
    if json_out {
        println!("{}", serde_json::to_string_pretty(&v)?);
        return Ok(());
    }
    let row = |f: &str, d: &Value| {
        let g = |k: &str| d.get(k).and_then(Value::as_str).unwrap_or("-").to_owned();
        let prefer = d
            .get("prefer")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(","))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "-".into());
        let env = d
            .get("env")
            .and_then(Value::as_object)
            .map(|o| o.keys().cloned().collect::<Vec<_>>().join(","))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "-".into());
        let profile = d
            .get("profile")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| "? (ambiguous)".into());
        println!(
            "{f:<12} {:<14} {:<34} {:<8} {:<14} {:<20} {env}",
            profile,
            g("model"),
            g("effort"),
            g("policy"),
            prefer
        );
    };
    println!(
        "{:<12} {:<14} {:<34} {:<8} {:<14} {:<20} ENV",
        "FAMILY", "PROFILE", "MODEL", "EFFORT", "POLICY", "PREFER"
    );
    match (&family, v.get("families").and_then(Value::as_object)) {
        (Some(f), _) => row(f, &v),
        (None, Some(fams)) => {
            for (f, d) in fams {
                row(f, d);
            }
        }
        _ => {}
    }
    Ok(())
}

/// `acpmux preset [NAME [key=value…]] [--clear]`.
pub(crate) async fn preset(
    client: Arc<Client>,
    name: Option<String>,
    pairs: Vec<String>,
    clear: bool,
    json_out: bool,
) -> Result<()> {
    let mut req = json!({});
    if let Some(n) = &name {
        req["name"] = json!(n);
    }
    if clear {
        if name.is_none() {
            return Err(AppError::usage("--clear needs a preset name").into());
        }
        req["clear"] = json!(true);
    }
    if !pairs.is_empty() {
        if name.is_none() {
            return Err(AppError::usage(
                "key=value pairs need a preset name: acpmux preset NAME harness=…",
            )
            .into());
        }
        let mut set = serde_json::Map::new();
        let mut env = serde_json::Map::new();
        for pair in &pairs {
            let (k, v) = pair
                .split_once('=')
                .ok_or_else(|| AppError::usage(format!("expected key=value, got {pair:?}")))?;
            match k {
                "harness" | "model" | "effort" | "policy" | "description" => {
                    set.insert(k.into(), if v.is_empty() { Value::Null } else { json!(v) });
                }
                _ if k.starts_with("env.") => {
                    env.insert(k[4..].into(), if v.is_empty() { Value::Null } else { json!(v) });
                }
                "env" if v.is_empty() => {
                    set.insert("env".into(), Value::Null);
                }
                // One JSON list of argv words: `args='["--tools", ""]'`; `args=` clears.
                "args" => {
                    let args = if v.is_empty() {
                        Value::Null
                    } else {
                        serde_json::from_str::<Vec<String>>(v).map(|a| json!(a)).map_err(|e| {
                            AppError::usage(format!("args must be a JSON list of strings: {e}"))
                        })?
                    };
                    set.insert("args".into(), args);
                }
                _ => return Err(AppError::usage(format!(
                    "unknown key {k:?}; use harness, model, effort, policy, description, env.KEY, args"
                ))
                .into()),
            }
        }
        if !env.is_empty() {
            set.insert("env".into(), Value::Object(env));
        }
        req["set"] = Value::Object(set);
    }
    let v = client.request(method::MUX_PRESETS, req).await?;
    if json_out {
        println!("{}", serde_json::to_string_pretty(&v)?);
        return Ok(());
    }
    let row = |p: &Value| {
        let g = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("-").to_owned();
        let env = p
            .get("env")
            .and_then(Value::as_object)
            .map(|o| {
                o.iter()
                    .map(|(k, v)| format!("{k}={}", v.as_str().unwrap_or("")))
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "-".into());
        let profile =
            p.get("profile").and_then(Value::as_str).map(str::to_owned).unwrap_or_else(|| {
                format!("? ({})", p.get("error").and_then(Value::as_str).unwrap_or("unresolved"))
            });
        println!(
            "{:<12} {:<12} {:<14} {:<34} {:<8} {:<14} {env}",
            g("name"),
            g("harness"),
            profile,
            g("model"),
            g("effort"),
            g("policy")
        );
    };
    println!(
        "{:<12} {:<12} {:<14} {:<34} {:<8} {:<14} ENV",
        "PRESET", "HARNESS", "PROFILE", "MODEL", "EFFORT", "POLICY"
    );
    match v.get("presets").and_then(Value::as_array) {
        Some(list) => {
            for p in list {
                row(p);
            }
        }
        None => row(&v),
    }
    Ok(())
}
