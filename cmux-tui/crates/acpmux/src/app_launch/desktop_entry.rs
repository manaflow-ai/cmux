//! A freedesktop desktop entry (`*.desktop`): what Linux opens an app by. Only what a launch
//! needs: `Name`, `Exec`, and whether it is an application a menu shows. Pure, so its tests run
//! on every platform.

/// One `[Desktop Entry]` group's launch fields.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub exec: String,
    /// `Type=Application`, not `Hidden`, not `NoDisplay`.
    pub shown: bool,
}

/// The `[Desktop Entry]` group of `text`. None without a `Name` or an `Exec`.
pub fn parse(text: &str) -> Option<Entry> {
    let mut entry = Entry::default();
    let (mut in_group, mut application, mut hidden) = (false, false, false);
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_group = line == "[Desktop Entry]";
            continue;
        }
        let Some((key, value)) = line.split_once('=').filter(|_| in_group) else { continue };
        let value = value.trim();
        match key.trim() {
            "Name" => entry.name = value.to_owned(),
            "Exec" => entry.exec = value.to_owned(),
            "Type" => application = value == "Application",
            "Hidden" | "NoDisplay" if value == "true" => hidden = true,
            _ => {}
        }
    }
    entry.shown = application && !hidden;
    (!entry.name.is_empty() && !entry.exec.is_empty()).then_some(entry)
}

/// `exec`'s argument vector with `args` in place of its field codes: `%f`/`%u` take the first
/// argument, `%F`/`%U` all of them, `%c` the entry's name, `%k` its file, and `%i`, `%d`, `%D`,
/// `%n`, `%N`, `%v`, `%m` go. An `Exec` with no file code gets the arguments at its end. Each
/// argument stays one element whatever it holds: no shell ever reads them. None for an `Exec`
/// that is not well formed (an open quote).
pub fn argv(exec: &str, args: &[String], name: &str, file: &str) -> Option<Vec<String>> {
    let mut out = Vec::new();
    let mut placed = false;
    for word in words(exec)? {
        match word.as_str() {
            "%f" | "%u" => {
                out.extend(args.first().cloned());
                placed = true;
            }
            "%F" | "%U" => {
                out.extend(args.iter().cloned());
                placed = true;
            }
            "%i" | "%d" | "%D" | "%n" | "%N" | "%v" | "%m" => {}
            _ => {
                let mut text = String::new();
                let mut chars = word.chars();
                while let Some(c) = chars.next() {
                    if c != '%' {
                        text.push(c);
                        continue;
                    }
                    match chars.next() {
                        Some('%') => text.push('%'),
                        Some('c') => text.push_str(name),
                        Some('k') => text.push_str(file),
                        // A file code inside a word, or a code the spec retired: dropped.
                        _ => {}
                    }
                }
                out.push(text);
            }
        }
    }
    if !placed {
        out.extend(args.iter().cloned());
    }
    (!out.is_empty()).then_some(out)
}

/// `Exec`'s words: split at spaces, a double-quoted word kept whole with `\"`, `` \` ``, `\$`
/// and `\\` unescaped in it (the spec's quoting).
fn words(exec: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut word = String::new();
    let (mut quoted, mut any) = (false, false);
    let mut chars = exec.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                quoted = !quoted;
                any = true;
            }
            '\\' if quoted => word.push(chars.next()?),
            ' ' | '\t' if !quoted => {
                if any || !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
                any = false;
            }
            _ => word.push(c),
        }
    }
    if quoted {
        return None;
    }
    if any || !word.is_empty() {
        words.push(word);
    }
    Some(words)
}
