//! The argument grammar: `--key value`, `--key=value` and bare words, as
//! `mux/host/src/main.ts` parses them.

use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Flags {
    pub values: BTreeMap<String, String>,
    pub words: Vec<String>,
}

impl Flags {
    pub fn parse(args: &[String]) -> Flags {
        let mut flags = Flags::default();
        let mut args = args.iter();
        while let Some(arg) = args.next() {
            if let Some(rest) = arg.strip_prefix("--") {
                if let Some((key, value)) = rest.split_once('=') {
                    flags.values.insert(key.to_owned(), value.to_owned());
                } else if let Some(value) = args.next() {
                    flags.values.insert(rest.to_owned(), value.clone());
                } else {
                    flags.words.push(arg.clone());
                }
            } else {
                flags.words.push(arg.clone());
            }
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
