//! Borrowed typed envelopes. Bulk fields stay as RawValue slices of the input.
use super::{BodyField, BodySource, Change, Error, Op, OwnedRow, RawRange};
use serde::{
    Deserialize, Deserializer,
    de::{SeqAccess, Visitor},
};
use serde_json::value::RawValue;
use std::{borrow::Cow, fmt};

pub(super) fn parse<'a, T: Deserialize<'a>>(bytes: &'a [u8]) -> Result<T, Error> {
    serde_json::from_slice(bytes).map_err(|_| Error::InvalidJson)
}
pub(super) fn value<'a, T: Deserialize<'a>>(raw: &'a RawValue) -> Result<T, Error> {
    parse(raw.get().as_bytes())
}
pub(super) fn text(raw: &RawValue) -> Result<Cow<'_, str>, Error> {
    struct Text;
    impl<'de> Visitor<'de> for Text {
        type Value = Cow<'de, str>;
        fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("a string")
        }
        fn visit_borrowed_str<E: serde::de::Error>(self, s: &'de str) -> Result<Self::Value, E> {
            Ok(Cow::Borrowed(s))
        }
        fn visit_str<E: serde::de::Error>(self, s: &str) -> Result<Self::Value, E> {
            Ok(Cow::Owned(s.into()))
        }
        fn visit_string<E: serde::de::Error>(self, s: String) -> Result<Self::Value, E> {
            Ok(Cow::Owned(s))
        }
    }
    let mut d = serde_json::Deserializer::from_str(raw.get());
    d.deserialize_str(Text).map_err(|_| Error::InvalidJson)
}
/// Visit array elements one at a time, without a Vec or a JSON tree.
pub(super) fn each<'a>(
    raw: &'a RawValue,
    mut f: impl FnMut(&'a RawValue) -> Result<(), Error>,
) -> Result<(), Error> {
    struct Items<'f, F>(&'f mut F);
    impl<'de, F: FnMut(&'de RawValue) -> Result<(), Error>> Visitor<'de> for Items<'_, F> {
        type Value = Result<(), Error>;
        fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("an array")
        }
        fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
            while let Some(raw) = seq.next_element::<&'de RawValue>()? {
                if let Err(e) = (self.0)(raw) {
                    return Ok(Err(e));
                }
            }
            Ok(Ok(()))
        }
    }
    let mut d = serde_json::Deserializer::from_str(raw.get());
    d.deserialize_seq(Items(&mut f)).map_err(|_| Error::InvalidJson)?
}
#[derive(Deserialize, Default)]
#[serde(default)]
pub(super) struct Meta<'a> {
    #[serde(borrow)]
    pub acpmux: Acpmux<'a>,
    #[serde(borrow)]
    pub provenance: Provenance<'a>,
    #[serde(borrow)]
    pub terminal_output: Terminal<'a>,
    #[serde(borrow)]
    pub claude: ClaudeMeta<'a>,
}
#[derive(Deserialize, Default)]
#[serde(default)]
pub(super) struct Acpmux<'a> {
    #[serde(borrow)]
    pub subagent: Option<&'a RawValue>,
    #[serde(borrow)]
    pub segment: Cow<'a, str>,
}
#[derive(Deserialize, Default)]
#[serde(default)]
pub(super) struct Provenance<'a> {
    #[serde(borrow)]
    pub kind: Cow<'a, str>,
}
#[derive(Deserialize, Default)]
#[serde(default)]
pub(super) struct Terminal<'a> {
    #[serde(borrow)]
    pub data: Option<&'a RawValue>,
}
#[derive(Deserialize, Default)]
#[serde(default)]
pub(super) struct ClaudeMeta<'a> {
    #[serde(borrow)]
    pub tool: Cow<'a, str>,
}
#[derive(Deserialize, Default)]
#[serde(default)]
pub(super) struct Block<'a> {
    #[serde(rename = "type", borrow)]
    pub kind: Cow<'a, str>,
    #[serde(borrow)]
    pub text: Option<&'a RawValue>,
    #[serde(borrow)]
    pub thinking: Option<&'a RawValue>,
    #[serde(borrow)]
    pub content: Option<&'a RawValue>,
    #[serde(borrow)]
    pub input: Option<&'a RawValue>,
    #[serde(borrow)]
    pub source: Option<&'a RawValue>,
    #[serde(borrow)]
    pub id: Cow<'a, str>,
    #[serde(borrow)]
    pub name: Cow<'a, str>,
    #[serde(borrow)]
    pub tool_use_id: Cow<'a, str>,
    pub is_error: bool,
}
/// Text blocks only. Tool/image/diff bulk content is passed through by its caller.
pub(super) fn content(
    raw: &RawValue,
    depth: u8,
    f: &mut impl FnMut(&str) -> Result<(), Error>,
) -> Result<(), Error> {
    if depth > 16 {
        return Err(Error::InvalidRecord("content nesting"));
    }
    if raw.get().starts_with('"') {
        return f(&text(raw)?);
    }
    if raw.get().starts_with('[') {
        return each(raw, |v| content(v, depth.saturating_add(1), f));
    }
    if raw.get() == "null" {
        return Ok(());
    }
    let block: Block<'_> = value(raw)?;
    match block.kind.as_ref() {
        "text" => {
            if let Some(raw) = block.text {
                f(&text(raw)?)?
            }
        }
        "thinking" => {
            if let Some(raw) = block.thinking {
                f(&text(raw)?)?
            }
        }
        "content" => {
            if let Some(raw) = block.content {
                content(raw, depth.saturating_add(1), f)?
            }
        }
        _ => {}
    }
    Ok(())
}

pub(super) struct Output<'a> {
    bytes: &'a [u8],
    pub ops: Vec<Op>,
}
impl<'a> Output<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, ops: Vec::new() }
    }
    pub fn row(&mut self, row: &OwnedRow) {
        self.emit(Change::Row(row.clone()))
    }
    pub fn emit(&mut self, change: Change) {
        self.ops.push(Op { raw: RawRange { offset: 0, length: self.bytes.len() }, change });
    }
    pub fn text(&mut self, id: u64, text: &str, _offset: usize) {
        // JSON escapes mean decoded text offsets do not map byte-for-byte to input;
        // use the complete source line as conservative provenance.
        self.ops.push(Op {
            raw: RawRange { offset: 0, length: self.bytes.len() },
            change: Change::Body {
                id,
                field: BodyField::Text,
                append: true,
                source: BodySource::Text(text.into()),
            },
        });
    }
    pub fn body(&mut self, id: u64, field: BodyField, append: bool, raw: &RawValue) {
        // RawValue is borrowed from `bytes` by serde_json, so this range cannot
        // fail for a validated harness line. Keeping it infallible prevents a
        // late provenance error from leaving checkpoint state ahead of its ops.
        let offset = (raw.get().as_ptr() as usize).saturating_sub(self.bytes.as_ptr() as usize);
        let range = RawRange { offset, length: raw.get().len() };
        debug_assert!(offset.saturating_add(range.length) <= self.bytes.len());
        self.emit(Change::Body { id, field, append, source: BodySource::Input(range) });
    }
}
