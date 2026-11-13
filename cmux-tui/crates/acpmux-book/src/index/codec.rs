//! Raw length-prefixed keys and bounded, extensible text JSON. No opaque parse.
use super::{ForkOf, IndexRecord, MAX_INDEX_RECORD_BYTES, RowKey, Summary};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::io::{self, Read};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TextRef<'a> {
    title: &'a str,
    harness: &'a str,
    state: &'a str,
    last_activity: u64,
    unread: u32,
    workspace: &'a Option<String>,
    pinned: bool,
    extra: &'a RawValue,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Text {
    title: String,
    harness: String,
    state: String,
    last_activity: u64,
    unread: u32,
    workspace: Option<String>,
    pinned: bool,
    extra: Box<RawValue>,
}

fn text(summary: &Summary) -> TextRef<'_> {
    TextRef {
        title: &summary.title,
        harness: &summary.harness,
        state: &summary.state,
        last_activity: summary.last_activity,
        unread: summary.unread,
        workspace: &summary.workspace,
        pinned: summary.pinned,
        extra: &summary.extra,
    }
}

pub(super) fn text_len(summary: &Summary) -> usize {
    serde_json::to_vec(&text(summary)).map_or(usize::MAX, |bytes| bytes.len())
}

fn string(out: &mut Vec<u8>, value: &str) -> io::Result<()> {
    let len = u16::try_from(value.len()).map_err(io::Error::other)?;
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(value.as_bytes());
    Ok(())
}

fn key(out: &mut Vec<u8>, value: &RowKey) -> io::Result<()> {
    value.validate()?;
    string(out, &value.origin)?;
    string(out, &value.chat_id)
}

pub(super) fn encode(record: &IndexRecord) -> io::Result<Vec<u8>> {
    let mut body = Vec::new();
    body.extend_from_slice(&record.seq.to_le_bytes());
    body.push(u8::from(record.gone));
    key(&mut body, &RowKey::new(record.origin.as_str(), record.chat_id.as_str()))?;
    if !record.gone {
        let s = &record.summary;
        s.validate()?;
        body.push(
            u8::from(s.parent.is_some())
                | (u8::from(s.fork_of.is_some()) << 1)
                | (u8::from(s.folder.is_some()) << 2),
        );
        if let Some(parent) = &s.parent {
            key(&mut body, parent)?;
        }
        if let Some(fork) = &s.fork_of {
            key(&mut body, &fork.key)?;
            body.extend_from_slice(&fork.seq.to_le_bytes());
        }
        if let Some(folder) = &s.folder {
            string(&mut body, folder)?;
        }
        serde_json::to_writer(&mut body, &text(s)).map_err(io::Error::other)?;
    }
    if body.len() + 8 > MAX_INDEX_RECORD_BYTES {
        return Err(invalid("oversize index record"));
    }
    let mut bytes = Vec::with_capacity(body.len() + 8);
    bytes.extend_from_slice(&(body.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&crc32fast::hash(&body).to_le_bytes());
    bytes.extend(body);
    Ok(bytes)
}

fn take_string(input: &mut &[u8], limit: usize) -> io::Result<String> {
    let mut len = [0; 2];
    input.read_exact(&mut len)?;
    let len = usize::from(u16::from_le_bytes(len));
    if len > limit {
        return Err(invalid("oversize key"));
    }
    let value = input.get(..len).ok_or_else(|| invalid("short key"))?;
    let value = std::str::from_utf8(value).map_err(io::Error::other)?.to_owned();
    *input = input.get(len..).ok_or_else(|| invalid("short key"))?;
    Ok(value)
}

fn take_key(input: &mut &[u8]) -> io::Result<RowKey> {
    Ok(RowKey::new(take_string(input, 256)?, take_string(input, 256)?))
}

pub(super) fn decode(mut input: &[u8]) -> io::Result<IndexRecord> {
    let mut seq = [0; 8];
    input.read_exact(&mut seq)?;
    let seq = u64::from_le_bytes(seq);
    let mut tag = [0];
    input.read_exact(&mut tag)?;
    let gone = match tag {
        [0] => false,
        [1] => true,
        _ => return Err(invalid("record kind")),
    };
    let row = take_key(&mut input)?;
    let mut summary = Summary::new(row.chat_id.to_string());
    summary.origin = row.origin.to_string();
    if !gone {
        input.read_exact(&mut tag)?;
        let flags = tag.first().copied().unwrap_or_default();
        if flags & !7 != 0 {
            return Err(invalid("record fields"));
        }
        if flags & 1 != 0 {
            summary.parent = Some(take_key(&mut input)?);
        }
        if flags & 2 != 0 {
            let key = take_key(&mut input)?;
            let mut seq = [0; 8];
            input.read_exact(&mut seq)?;
            summary.fork_of = Some(ForkOf { key, seq: u64::from_le_bytes(seq) });
        }
        if flags & 4 != 0 {
            summary.folder = Some(take_string(&mut input, 1024)?);
        }
        if input.len() > super::MAX_SUMMARY_BYTES {
            return Err(invalid("oversize text"));
        }
        let text: Text = serde_json::from_slice(input).map_err(io::Error::other)?;
        summary.title = text.title;
        summary.harness = text.harness;
        summary.state = text.state;
        summary.last_activity = text.last_activity;
        summary.unread = text.unread;
        summary.workspace = text.workspace;
        summary.pinned = text.pinned;
        summary.extra = text.extra;
        summary.validate()?;
    } else if !input.is_empty() {
        return Err(invalid("gone trailing bytes"));
    }
    Ok(IndexRecord {
        seq,
        chat_id: row.chat_id.to_string(),
        origin: row.origin.to_string(),
        summary,
        gone,
    })
}

pub(super) fn read(reader: &mut impl Read) -> io::Result<Option<(IndexRecord, usize)>> {
    let mut header = [0; 8];
    let read = reader.read(&mut header)?;
    if read == 0 {
        return Ok(None);
    }
    reader.read_exact(header.get_mut(read..).ok_or_else(|| invalid("record header"))?)?;
    let len = u32::from_le_bytes(
        header.get(..4).ok_or_else(|| invalid("length"))?.try_into().map_err(io::Error::other)?,
    ) as usize;
    let crc = u32::from_le_bytes(
        header.get(4..).ok_or_else(|| invalid("crc"))?.try_into().map_err(io::Error::other)?,
    );
    if len > MAX_INDEX_RECORD_BYTES - 8 {
        return Err(invalid("record length"));
    }
    let mut body = vec![0; len];
    reader.read_exact(&mut body)?;
    if crc32fast::hash(&body) != crc {
        return Err(invalid("record crc"));
    }
    Ok(Some((decode(&body)?, len + 8)))
}

pub(super) fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
