# Attachment upload: every stage bounded, resumable, cancellable

Lane ios-attachment-send, 2026-11-24. Case: Leo's iPhone on LTE sending a video to a terminal
agent session on his Mac hung forever and could not be cancelled (relayed, 08:29Z):

> "i also tried to send you a video and like it just blocked me endlessly on a send. it just
> couldnt load or whatever idk at which point of the protocol i got f***ed on but you know what i
> mean. ... i also couldnt cancel out of the send. i need to be able to do that otherwise i cant
> edit or anything to retry or delete and remove."

## The path before this change (feat-cmux-next 34cae780)

| # | Stage | Code | Timeout | Progress | Cancel | Retry |
|---|---|---|---|---|---|---|
| 1 | Picker export (Photos copies the video to a temp file; iCloud originals download first) | `TerminalComposer.swift:322` `loadPhotos` → `loadTransferable(type: MovieFile.self)`; chat: `ChatComposer.swift:736` | **none** | **none** (no tile until the copy ends) | **none** | none (`try?` drops a failure silently) |
| 2 | Compression | none: the original (4K HEVC/H.264, ~170-400 MB/min) is sent as is | - | - | - | - |
| 3 | Upload starts | only on Send: `TerminalModel.swift:731` `sendAttachments`, sequential per attachment | - | - | - | - |
| 4 | Channel open | `LinkUpload.swift:91` `link.openChannel(service: "upload")` | **none** | - | task cancel only | none |
| 5 | Byte stream, 192 KiB writes | `LinkUpload.swift:102-114`; link outbox `link.rs:2115` `send_marked` | **none** of its own; only the link's 45 s keepalive (`link.rs:163`) ends a dead link | **none** (a spinner, `TerminalComposer.swift:254`) | `uploadTask` exists (`TerminalModel.swift:118`) but **nothing ever cancels it**; Send is disabled while uploading (`TerminalComposer.swift:275`) | **none**: a dropped link fails the whole send; the person's retry starts at byte 0 |
| 6 | Mac write | `services.rs:2162` `receive_upload`: `.part` named by a fresh UUID, deleted on any early end | **none**: `receiver.recv()` waits as long as the channel lives | - | channel close | none: the part is deleted, nothing to resume from |
| 7 | Mac reply `{"path"}` | `LinkUpload.swift:115-118` reads until eof | **none** | - | - | - |
| 8 | Paste of the path into the agent | `TerminalModel.swift:754` `surface.perform(ComposerSubmit)` | input lane, no ack | - | - | - |

Stages 1, 4, 5, 6 and 7 have no bound. Over LTE on a relayed path (1-5 Mbit/s up) a 400 MB
original takes 11-53 minutes with a spinner and no number: indistinguishable from a hang, and with
no way out but killing the app.

## The design

### Wire: `upload` resumes (hostd and phone, backward compatible)

Args gain `upload_id` (36 chars, `[0-9a-f-]`, chosen by the phone, stable across attempts of one
attachment) and `offset` (decimal string, the byte the phone starts at). `size` stays the whole
file's size.

hostd with `upload_id`:
- keeps the part at `<folder>/.<upload_id>.part` (not a fresh UUID) so a later attempt finds it;
- `offset` greater than the part's length: answers `{"error":"resume_gap","have":L}` and closes
  `resume_gap`; the phone reopens at `L`;
- otherwise truncates the part to `offset` and answers `{"have":offset}` at once, before reading;
- answers `{"ack":N}` (N = bytes in the part) each 1 MiB written and when the bytes stop;
- at `size` bytes: fsync, publish under the safe name, answer `{"path","size"}`, close `eof`;
- an early end (link lost, stall, close) keeps the part for a later attempt; no data for 120 s
  closes `stalled` and keeps it; parts untouched for 24 h are removed when the folder is next used;
- every reply is one JSON object per line (`\n`-terminated).

hostd without `upload_id` (an older phone): unchanged.

A phone talking to an older hostd sees no `have`: it sends from 0 as before, with no acks, and a
retry starts at 0 again. The phone sends `offset > 0` only to a Mac that answered `have` for this
upload.

### Phone: one Rust engine, `AttachmentUploads` (cmux-mobile-link-ffi `attachment_upload.rs`)

- Starts when the attachment is picked, not on Send: the bytes move while he types.
- Swift hands it the Mac's current `LinkHandle` whenever the link changes (`set_link`); an upload
  waiting for a link resumes on the next one.
- Bounds: open 15 s; `have` 10 s; no ack advance for 30 s with bytes outstanding = stalled; the
  final answer 60 s after the last byte; each ends the attempt, never the upload.
- Retries from the last acked byte with backoff (0.5 s doubling to 10 s). It fails, with a
  sentence, only on a refusal no retry fixes (`bad_request`, `io`, `forbidden` after the
  uploads-folder fallback) or after 5 minutes with no new acked byte.
- `cancel(id)` returns at once: the attempt's channel closes `cancelled`, the waiters get
  `cancelled`, and the composer is already free (it never waited).
- Progress per ack to an observer: stage (`compressing`, `waiting_for_mac`, `uploading`,
  `finishing`, `done`, `failed`, `cancelled`), acked bytes, total, attempt.

### Compression policy (Rust decides, the platform encoder encodes)

`video_plan(width, height, duration_ms, bytes, codec) -> Plan`: send the original when it is
small (≤ 25 MB) or already ≤ 1080p at ≤ 12 Mbit/s; otherwise re-encode to HEVC with the long side at
most 1920 px (`AVAssetExportPresetHEVC1920x1080`). A 1-minute 4K clip goes from about 400 MB
(H.264) / 170 MB (HEVC) to about 40-60 MB. Swift runs `AVAssetExportSession`, reporting its
progress as the `compressing` stage; cancel stops the export.

### What it does not do

- Upload while a re-encode is still writing: the export rewrites the container's header at the end,
  so bytes sent early can be wrong. The upload starts the moment the export ends, which is at pick
  time, long before Send.
- Background upload with the app suspended: the link parks (`link.rs:63`) and the upload resumes
  from its last ack when the app returns.

## Next: transfer early, send less, wait on progress (Leo, 2026-11-24)

Leo: "attachments and s**t potentially need to be optimistically transferred from phone to mac...
and the size needs to be optimized too". And: "10s timeout for messages being sendsble is a shame.
if it's making good progress, it shiukd be allowed to keep going?"

What already holds before this section:

- Pick-time transfer: the engine starts the upload when the attachment is picked, not at Send.
- Resume from the last acked byte (#53651, acks durable per MiB) and per-attempt bounds that retry.
- The upload itself fails only after 5 minutes with no new acked byte: progress-based already.
- Chunk-level dedup for files ≤ 64 MiB over `bundle` (#54356): a re-send crosses only the chunks
  the Mac lacks.

What this section adds:

1. **Whole-file dedup by hash, any size.** The engine hashes the file (SHA-256, streamed, off the
   main thread) while it compresses or before the first byte. `upload` open carries `sha256`; hostd
   keeps an index `sha256 -> stored path` of finished uploads and answers `final` with that path and
   no bytes when it has it (verifying size and hash of the stored file first). An older Mac ignores
   the field and the upload proceeds as today.
2. **Images sized to what the agent needs.** `image_plan(width, height, bytes, format) -> ImagePlan`
   in Rust: send the original when its long side is ≤ 2048 px and it is ≤ 2 MiB; otherwise downscale to
   a long side of 2048 px and re-encode JPEG q 0.85 (HEIC in, JPEG out: agents read JPEG). Swift glue
   runs ImageIO (`CGImageSourceCreateThumbnailAtIndex`) and reports it as `compressing`. Screenshots
   with text stay legible at 2048 px.
3. **Original on demand.** When a plan re-encoded, the composer chip keeps the original's local
   identifier and offers "Send original"; it starts a second upload of the untouched file, deduped
   like any other. The agent's message names the sent copy's size, so the agent can ask for it.
4. **Progress-based deadlines, not fixed ones.** A held chat prompt comes back to the composer after
   10 s (`AcpmuxHub.heldPromptWindow`). It becomes: held while its attachment upload or the link's
   redial makes progress, and returned only after 10 s with no progress. The other fixed bounds on
   the attach path (open 15 s, have 10 s, final 60 s) already end an attempt, not the send.

Measured before and after, on lte and lossy-3, idle and under duress: bytes on the wire and time
from pick to "sent" for a 12 MP photo, a 1-minute 4K clip, and a re-send of each.
