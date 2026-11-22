//! The argument grammar: `--key value`, `--key=value` and bare words, as
//! `mux/host/src/main.ts` parses them.

use std::collections::BTreeMap;

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Flags {
    pub values: BTreeMap<String, String>,
    pub words: Vec<String>,
}

impl Flags {
    pub fn parse(args: &[String]) -> Flags {
        let mut flags = Flags::default();
        let mut i = 0;
        while i < args.len() {
            let arg = &args[i];
            if let Some(rest) = arg.strip_prefix("--") {
                if let Some((key, value)) = rest.split_once('=') {
                    flags.values.insert(key.to_owned(), value.to_owned());
                } else if i + 1 < args.len() {
                    flags.values.insert(rest.to_owned(), args[i + 1].clone());
                    i += 1;
                } else {
                    flags.words.push(arg.clone());
                }
            } else {
                flags.words.push(arg.clone());
            }
            i += 1;
        }
        flags
    }

    pub fn value(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }
}

/// A non-empty environment variable.
pub fn env(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_and_words() {
        let args: Vec<String> = ["host", "--daemon-socket", "/s", "--mux-home=/h", "x"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let f = Flags::parse(&args);
        assert_eq!(f.value("daemon-socket"), Some("/s"));
        assert_eq!(f.value("mux-home"), Some("/h"));
        assert_eq!(f.words, vec!["host", "x"]);
    }
}
