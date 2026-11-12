//! A check that a text is one compact JSON value. A row's body is built by the translator and
//! copied into the row text as it is; this is the one look the book takes at it, at encode time,
//! so a malformed body can never reach a segment or a client. Nothing is built: no tree, no copy.

/// Nesting deeper than this is refused (a body is a few levels deep).
const MAX_DEPTH: u32 = 64;

/// Whether `text` is exactly one JSON value with no whitespace outside its strings.
pub(crate) fn is_compact_value(text: &str) -> bool {
    let mut cursor = Cursor { bytes: text.as_bytes(), at: 0 };
    cursor.value(0) && cursor.at == cursor.bytes.len()
}

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
        if self.eat(b'}') {
            return true;
        }
        loop {
            if !self.string() || !self.eat(b':') || !self.value(depth.saturating_add(1)) {
                return false;
            }
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
        if self.eat(b']') {
            return true;
        }
        loop {
            if !self.value(depth.saturating_add(1)) {
                return false;
            }
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
                            for _ in 0..4 {
                                if !self.peek().is_some_and(|byte| byte.is_ascii_hexdigit()) {
                                    return false;
                                }
                                self.bump();
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
