//! The brain knows itself as `agent_mux` (the wake rule, its read cursor, the
//! outbox). In the cloud the chief is `agent_<chief id>`. The port rewrites
//! exact JSON string values and object keys between the two, so the brain
//! runs unchanged; text that merely contains the id is never rewritten.

use cmux_chief::rules::AGENT_MUX;
use serde_json::Value;

/// Cloud shape to brain shape: the chief id becomes `agent_mux`.
pub fn to_brain(value: &mut Value, chief: &str) {
    rewrite(value, chief, AGENT_MUX);
}

/// Brain shape to cloud shape: `agent_mux` becomes the chief id.
pub fn to_cloud(value: &mut Value, chief: &str) {
    rewrite(value, AGENT_MUX, chief);
}

fn rewrite(value: &mut Value, from: &str, to: &str) {
    match value {
        Value::String(s) if s == from => *s = to.to_owned(),
        Value::Array(items) => items.iter_mut().for_each(|v| rewrite(v, from, to)),
        Value::Object(map) => {
            if let Some(v) = map.remove(from) {
                map.insert(to.to_owned(), v);
            }
            for (key, v) in map.iter_mut() {
                // A message's text is the person's words, not an id.
                if key != "text" && key != "preview" && key != "title" {
                    rewrite(v, from, to);
                }
            }
        }
        _ => {}
    }
}
