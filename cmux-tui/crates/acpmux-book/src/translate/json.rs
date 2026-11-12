//! Borrowed JSON fields, never a tree. Unknown bodies are validated and skipped in place.
//! Seeded from the book's compact JSON validator; whitespace is permitted in harness input.
use std::borrow::Cow;

const MAX_DEPTH: u32 = 64;

#[derive(Clone, Copy, Debug)]
pub(super) struct Json<'a>(&'a str);

impl<'a> Json<'a> {
    pub fn parse(bytes: &'a [u8]) -> Option<Self> {
        let text = std::str::from_utf8(bytes).ok()?;
        let mut c = Cursor { bytes, at: 0 };
        if !c.value(0) {
            return None;
        }
        c.space();
        (c.at == bytes.len()).then_some(Self(text.trim()))
    }
    pub fn number(self) -> Option<u64> {
        self.0.parse().ok()
    }
    pub fn yes(self) -> bool {
        self.0 == "true"
    }
    pub fn null(self) -> bool {
        self.0 == "null"
    }
    pub fn string(self) -> Option<Cow<'a, str>> {
        let inner = self.0.strip_prefix('"')?.strip_suffix('"')?;
        if !inner.contains('\\') {
            return Some(Cow::Borrowed(inner));
        }
        let mut out = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(ch) = chars.next() {
            if ch != '\\' {
                out.push(ch);
                continue;
            }
            out.push(match chars.next()? {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => '\u{8}',
                'f' => '\u{c}',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => {
                    let high = hex4(&mut chars)?;
                    let point = if (0xd800..=0xdbff).contains(&high) {
                        if chars.next()? != '\\' || chars.next()? != 'u' {
                            return None;
                        }
                        let low = hex4(&mut chars)?;
                        if !(0xdc00..=0xdfff).contains(&low) {
                            return None;
                        }
                        0x10000u32
                            .saturating_add(high.saturating_sub(0xd800).saturating_mul(1024))
                            .saturating_add(low.saturating_sub(0xdc00))
                    } else {
                        high
                    };
                    char::from_u32(point)?
                }
                _ => return None,
            });
        }
        Some(Cow::Owned(out))
    }
    pub fn get(self, key: &str) -> Option<Self> {
        self.fields()?.find_map(|(k, v)| (k.string().as_deref() == Some(key)).then_some(v))
    }
    pub fn path(self, keys: &[&str]) -> Option<Self> {
        keys.iter().try_fold(self, |v, k| v.get(k))
    }
    pub fn text(self, key: &str) -> Option<Cow<'a, str>> {
        self.get(key)?.string()
    }
    pub fn fields(self) -> Option<Fields<'a>> {
        self.0.starts_with('{').then_some(Fields(Cursor { bytes: self.0.as_bytes(), at: 1 }))
    }
    pub fn items(self) -> Option<Items<'a>> {
        self.0.starts_with('[').then_some(Items(Cursor { bytes: self.0.as_bytes(), at: 1 }))
    }
    /// Compact only a displayed field; cold fields remain borrowed and are never copied.
    pub fn compact(self) -> String {
        let mut out = String::new();
        let mut string = false;
        let mut escaped = false;
        for c in self.0.chars() {
            if string {
                out.push(c);
                if escaped {
                    escaped = false;
                } else if c == '\\' {
                    escaped = true;
                } else if c == '"' {
                    string = false;
                }
            } else if c == '"' {
                string = true;
                out.push(c);
            } else if !c.is_ascii_whitespace() {
                out.push(c);
            }
        }
        out
    }
}
fn hex4(chars: &mut std::str::Chars<'_>) -> Option<u32> {
    (0..4).try_fold(0u32, |n, _| Some(n.checked_mul(16)?.checked_add(chars.next()?.to_digit(16)?)?))
}
pub(super) struct Fields<'a>(Cursor<'a>);
impl<'a> Iterator for Fields<'a> {
    type Item = (Json<'a>, Json<'a>);
    fn next(&mut self) -> Option<Self::Item> {
        self.0.space();
        if self.0.peek() == Some(b'}') {
            return None;
        }
        let key = self.0.take()?;
        self.0.space();
        if !self.0.eat(b':') {
            return None;
        }
        let value = self.0.take()?;
        self.0.space();
        self.0.eat(b',');
        Some((key, value))
    }
}
pub(super) struct Items<'a>(Cursor<'a>);
impl<'a> Iterator for Items<'a> {
    type Item = Json<'a>;
    fn next(&mut self) -> Option<Self::Item> {
        self.0.space();
        if self.0.peek() == Some(b']') {
            return None;
        }
        let value = self.0.take()?;
        self.0.space();
        self.0.eat(b',');
        Some(value)
    }
}
impl<'a> Cursor<'a> {
    fn take(&mut self) -> Option<Json<'a>> {
        self.space();
        let start = self.at;
        if !self.value(0) {
            return None;
        }
        Some(Json(std::str::from_utf8(self.bytes.get(start..self.at)?).ok()?))
    }
}
#[derive(Clone)]
struct Cursor<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Cursor<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn bump(&mut self) {
        self.at = self.at.saturating_add(1);
    }

    fn space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.bump();
        }
    }

    fn eat(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.bump();
            return true;
        }
        false
    }

    fn literal(&mut self, word: &[u8]) -> bool {
        if self.bytes.get(self.at..).is_some_and(|rest| rest.starts_with(word)) {
            self.at = self.at.saturating_add(word.len());
            return true;
        }
        false
    }

    fn value(&mut self, depth: u32) -> bool {
        self.space();
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => self.string(),
            Some(b't') => self.literal(b"true"),
            Some(b'f') => self.literal(b"false"),
            Some(b'n') => self.literal(b"null"),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => false,
        }
    }

    fn object(&mut self, depth: u32) -> bool {
        if depth >= MAX_DEPTH {
            return false;
        }
        self.bump();
        self.space();
        if self.eat(b'}') {
            return true;
        }
        loop {
            self.space();
            if !self.string() {
                return false;
            }
            self.space();
            if !self.eat(b':') || !self.value(depth.saturating_add(1)) {
                return false;
            }
            self.space();
            if !self.eat(b',') {
                return self.eat(b'}');
            }
        }
    }

    fn array(&mut self, depth: u32) -> bool {
        if depth >= MAX_DEPTH {
            return false;
        }
        self.bump();
        self.space();
        if self.eat(b']') {
            return true;
        }
        loop {
            if !self.value(depth.saturating_add(1)) {
                return false;
            }
            self.space();
            if !self.eat(b',') {
                return self.eat(b']');
            }
        }
    }

    fn string(&mut self) -> bool {
        if !self.eat(b'"') {
            return false;
        }
        loop {
            match self.peek() {
                None => return false,
                Some(b'"') => {
                    self.bump();
                    return true;
                }
                Some(b'\\') => {
                    self.bump();
                    match self.peek() {
                        Some(b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't') => self.bump(),
                        Some(b'u') => {
                            self.bump();
                            let Some(high) = self.hex() else {
                                return false;
                            };
                            if (0xd800..=0xdbff).contains(&high) {
                                if !self.eat(b'\\') || !self.eat(b'u') {
                                    return false;
                                }
                                let Some(low) = self.hex() else {
                                    return false;
                                };
                                if !(0xdc00..=0xdfff).contains(&low) {
                                    return false;
                                }
                            } else if (0xdc00..=0xdfff).contains(&high) {
                                return false;
                            }
                        }
                        _ => return false,
                    }
                }
                // A raw control character is not JSON; it would also break a line-framed reader.
                Some(byte) if byte < 0x20 => return false,
                Some(_) => self.bump(),
            }
        }
    }

    fn hex(&mut self) -> Option<u32> {
        let mut n = 0u32;
        for _ in 0..4 {
            n = n.checked_mul(16)?.checked_add(char::from(self.peek()?).to_digit(16)?)?;
            self.bump();
        }
        Some(n)
    }

    fn digits(&mut self) -> bool {
        let start = self.at;
        while self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
            self.bump();
        }
        self.at > start
    }

    fn number(&mut self) -> bool {
        self.eat(b'-');
        match self.peek() {
            Some(b'0') => self.bump(),
            Some(b'1'..=b'9') => {
                self.digits();
            }
            _ => return false,
        }
        if self.eat(b'.') && !self.digits() {
            return false;
        }
        if self.eat(b'e') || self.eat(b'E') {
            if !self.eat(b'+') {
                self.eat(b'-');
            }
            if !self.digits() {
                return false;
            }
        }
        true
    }
}
