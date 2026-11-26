//! One canonical text of a JSON value (acpmux `canonical_json`, `PushJSON.canonical` in Swift):
//! object keys in UTF-8 byte order, no whitespace, only `"`, `\` and control characters escaped,
//! integers only. The Mac hashes this text, so every byte counts.

use serde_json::Value;

/// A value with a number that is not an integer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("canonical JSON takes integers only")]
pub struct NotCanonical;

pub fn canonical(value: &Value) -> Result<String, NotCanonical> {
    let mut out = String::new();
    write(value, &mut out)?;
    Ok(out)
}

fn write(value: &Value, out: &mut String) -> Result<(), NotCanonical> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            if n.is_i64() || n.is_u64() {
                out.push_str(&n.to_string());
            } else {
                return Err(NotCanonical);
            }
        }
        Value::String(s) => string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write(item, out)?;
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
            out.push('{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                string(key, out);
                out.push(':');
                write(&map[key], out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keys_sort_by_bytes_and_escapes_match_swift() {
        let v = json!({"b": 1, "a": {"z": [true, null, "x\u{1}\u{8}\u{c}\n\r\t\"\\é"], "Z": -2}, "é": 3});
        assert_eq!(
            canonical(&v).unwrap(),
            "{\"a\":{\"Z\":-2,\"z\":[true,null,\"x\\u0001\\b\\f\\n\\r\\t\\\"\\\\é\"]},\"b\":1,\"é\":3}"
        );
        assert_eq!(canonical(&json!({"f": 1.5})), Err(NotCanonical));
    }
}
