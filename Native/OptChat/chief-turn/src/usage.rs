use serde_json::Value;

/// Token counts of one Messages API response (or a turn's sum), as Claude
/// Code reports them. Section 8 says to verify caching with these: each
/// request should read what the previous one wrote.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Usage {
    /// Uncached input tokens (full price).
    pub input: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub output: u64,
}

impl Usage {
    /// The Anthropic `usage` object; None when it has no token counts.
    pub fn parse(usage: &Value) -> Option<Usage> {
        let n = |k: &str| usage.get(k).and_then(Value::as_u64);
        let input = n("input_tokens")?;
        Some(Usage {
            input,
            cache_read: n("cache_read_input_tokens").unwrap_or(0),
            cache_write: n("cache_creation_input_tokens").unwrap_or(0),
            output: n("output_tokens").unwrap_or(0),
        })
    }

    /// The same counts with every missing one as 0 (a `result` line whose
    /// usage may lack fields), never None.
    pub fn parse_lenient(usage: Option<&Value>) -> Usage {
        let n = |k: &str| {
            usage
                .and_then(|u| u.get(k))
                .and_then(Value::as_u64)
                .unwrap_or(0)
        };
        Usage {
            input: n("input_tokens"),
            cache_read: n("cache_read_input_tokens"),
            cache_write: n("cache_creation_input_tokens"),
            output: n("output_tokens"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_needs_input_tokens() {
        assert_eq!(Usage::parse(&json!({"output_tokens": 3})), None);
        assert_eq!(
            Usage::parse(
                &json!({"input_tokens": 1, "output_tokens": 3, "cache_read_input_tokens": 7})
            ),
            Some(Usage {
                input: 1,
                cache_read: 7,
                cache_write: 0,
                output: 3
            })
        );
    }

    #[test]
    fn lenient_fills_zeros() {
        assert_eq!(Usage::parse_lenient(None), Usage::default());
        assert_eq!(
            Usage::parse_lenient(Some(&json!({"output_tokens": 2}))).output,
            2
        );
    }
}
