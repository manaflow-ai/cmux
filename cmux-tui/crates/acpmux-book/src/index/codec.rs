//! Raw length-prefixed keys and bounded, extensible text JSON. No opaque parse.
use super::{
    ForkOf, IndexRecord, MAX_INDEX_RECORD_BYTES, OriginRecord, OriginState, RowKey, Summary,
};
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
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    archived: bool,
    peer_form: &'a Option<Box<RawValue>>,
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
    #[serde(default)]
    archived: bool,
    peer_form: Option<Box<RawValue>>,
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
        archived: summary.archived,
        peer_form: &summary.peer_form,
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
    let value = std::str::from_utf8(value)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
        .to_owned();
    *input = input.get(len..).ok_or_else(|| invalid("short key"))?;
    Ok(value)
}

fn take_key(input: &mut &[u8]) -> io::Result<RowKey> {
    Ok(RowKey::new(take_string(input, 256)?, take_string(input, 256)?))
}

pub(super) enum LogRecord {
    Row(Box<IndexRecord>),
    Origin(OriginRecord),
}

pub(super) fn decode(mut input: &[u8]) -> io::Result<LogRecord> {
    let mut seq = [0; 8];
    input.read_exact(&mut seq)?;
    let seq = u64::from_le_bytes(seq);
    let mut tag = [0];
    input.read_exact(&mut tag)?;
    if tag == [2] {
        let id = take_string(&mut input, 256)?;
        let mut state = [0];
        input.read_exact(&mut state)?;
        let state = match state {
            [0] => OriginState::Connected,
            [1] => OriginState::Down,
            [2] => OriginState::Stale,
            [3] => OriginState::Removed,
            _ => return Err(invalid("origin state")),
        };
        let mut since = [0; 8];
        input.read_exact(&mut since)?;
        let mut extra = None;
        let mut has_extra = [0];
        input.read_exact(&mut has_extra)?;
        if has_extra == [1] {
            let mut len = [0; 2];
            input.read_exact(&mut len)?;
            let len = usize::from(u16::from_le_bytes(len));
            if len > 512 {
                return Err(invalid("origin extra"));
            }
            let bytes = input.get(..len).ok_or_else(|| invalid("origin extra"))?;
            extra = Some(
                RawValue::from_string(
                    std::str::from_utf8(bytes)
                        .map_err(|_| invalid("origin extra utf8"))?
                        .to_owned(),
                )
                .map_err(|_| invalid("origin extra json"))?,
            );
            input = input.get(len..).ok_or_else(|| invalid("origin extra"))?;
        } else if has_extra != [0] {
            return Err(invalid("origin extra flag"));
        }
        if !input.is_empty() {
            return Err(invalid("origin trailing bytes"));
        }
        return Ok(LogRecord::Origin(OriginRecord {
            seq,
            id,
            state,
            since: u64::from_le_bytes(since),
            extra,
        }));
    }
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
        let text: Text = serde_json::from_slice(input)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        summary.title = text.title;
        summary.harness = text.harness;
        summary.state = text.state;
        summary.last_activity = text.last_activity;
        summary.unread = text.unread;
        summary.workspace = text.workspace;
        summary.pinned = text.pinned;
        summary.archived = text.archived;
        summary.peer_form = text.peer_form;
        summary.extra = text.extra;
        summary.validate()?;
    } else if !input.is_empty() {
        return Err(invalid("gone trailing bytes"));
    }
    Ok(LogRecord::Row(Box::new(IndexRecord {
        seq,
        chat_id: row.chat_id.to_string(),
        origin: row.origin.to_string(),
        summary,
        gone,
    })))
}

pub(super) fn read_any(reader: &mut impl Read) -> io::Result<Option<(LogRecord, usize)>> {
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

pub(super) fn read(reader: &mut impl Read) -> io::Result<Option<(IndexRecord, usize)>> {
    match read_any(reader)? {
        Some((LogRecord::Row(record), len)) => Ok(Some((*record, len))),
        Some((LogRecord::Origin(_), _)) => Err(invalid("origin record in snapshot")),
        None => Ok(None),
    }
}

pub(super) fn encode_origin(seq: u64, record: &OriginRecord) -> io::Result<Vec<u8>> {
    if record.id.len() > 256 {
        return Err(invalid("origin id"));
    }
    let mut body = Vec::new();
    body.extend_from_slice(&seq.to_le_bytes());
    body.push(2);
    string(&mut body, &record.id)?;
    body.push(match record.state {
        OriginState::Connected => 0,
        OriginState::Down => 1,
        OriginState::Stale => 2,
        OriginState::Removed => 3,
    });
    body.extend_from_slice(&record.since.to_le_bytes());
    if let Some(extra) = &record.extra {
        let bytes = extra.get().as_bytes();
        if bytes.len() > 512 || std::str::from_utf8(bytes).is_err() {
            return Err(invalid("origin extra"));
        }
        body.push(1);
        body.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
        body.extend_from_slice(bytes);
    } else {
        body.push(0);
    }
    if body.len() + 8 > MAX_INDEX_RECORD_BYTES {
        return Err(invalid("oversize origin record"));
    }
    let mut bytes = Vec::with_capacity(body.len() + 8);
    bytes.extend_from_slice(&(body.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&crc32fast::hash(&body).to_le_bytes());
    bytes.extend(body);
    Ok(bytes)
}

pub(super) fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pre_peer_form_records_still_decode() {
        // Fields of 5b's length-prefixed record, followed by its text object.
        let mut bytes = 7u64.to_le_bytes().to_vec();
        bytes.push(0);
        key(&mut bytes, &RowKey::new("local", "old")).unwrap();
        bytes.push(0);
        bytes.extend_from_slice(br#"{"title":"old","harness":"claude","state":"closed","lastActivity":42,"unread":0,"workspace":null,"pinned":false,"extra":{"name":"old"}}"#);
        let row = match decode(&bytes).unwrap() {
            LogRecord::Row(row) => row,
            LogRecord::Origin(_) => panic!("expected a row record"),
        };
        assert_eq!(row.seq, 7);
        assert_eq!(row.summary.chat_id, "old");
        assert!(row.summary.peer_form.is_none());
        assert!(!row.summary.archived);
        assert_eq!(row.summary.extra.get(), r#"{"name":"old"}"#);
    }
}
