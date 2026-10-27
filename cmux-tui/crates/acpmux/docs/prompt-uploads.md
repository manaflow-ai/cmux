# Prompt uploads: files of any size, sent by reference

The contract between a client that sends files with a prompt and the acpmux daemon. A typical
client is the cmux app's native upload worker.

Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE".

- No size or count cap on files: no limit per file, on the files of one prompt together, or on
  how many a chat holds.
- One prompt is still one JSON-RPC message (`rpc::MAX_MESSAGE_BYTES`, 15 MiB) on every hop. That
  bounds the prompt's own text and references, never the files' bytes. A reference with its
  path note is a few hundred bytes, so one prompt names tens of thousands of files. A prompt
  whose references alone would not fit is refused with `upload.tooMany`; send the files in more
  than one prompt.
- No base64 in the page binding: file bytes go from the app's native side to the daemon, never
  through the page.
- The prompt names the uploads and stays a few hundred bytes.
- The only failure about a file's size is a full disk on the receiving host, and that error names
  the host and path.

Who owns what: the daemon owns this API (upload calls, the reference resolver, peer forwarding,
feature flags). The native app owns its own host-authenticated endpoint, origin and gesture
binding, and calls this API over its daemon connection.

## 0. What exists at which head

| part | status |
|---|---|
| `file_put_begin` / `_chunk` (base64, at most 512 KiB a chunk) / `_finish` / `_cancel`, no size cap | landed, #25730 |
| upload-ref blocks in `session/prompt` (section 5), what the agent gets (section 6), dedupe (section 7) | landed, #25730 |
| `promptUploads` feature flag | landed, #25730 |
| `_acpmux/file_put_status`, finish `sha256` and its `{path, size, uploadId}` answer, the `upload.*` error reasons, `upload.diskFull` | #25793, flag `uploadResume` |
| binary data frames `_acpmux/file_put_data` on the app's WebSocket, peer chats included | #25803, flag `uploadFrames` |
| `acpmux send --attach` and `send_message` send any size and number by reference (no 8 MiB / 10 MiB / 16-file refusal), begin `forPrompt`, `owned` references deleted when their prompt is refused, cancel deletes a finished upload | #25840 |

A native caller checks the flags, not the PRs. Without `uploadFrames` it sends data with
`_acpmux/file_put_chunk`; the base64 then travels only on the native-to-daemon socket, never on
the page binding.

## Capability flags

These are listed in the `initialize` result, `_meta.acpmux.features`.

| flag | means |
|---|---|
| `promptUploads` | the daemon resolves upload-ref blocks in `session/prompt`, and resumable uploads have no size cap |
| `uploadResume` | `_acpmux/file_put_status`, finish `sha256`, the `upload.*` reasons and `upload.diskFull` (sections 3, 4) |
| `uploadFrames` | the daemon takes binary data frames on the app's WebSocket (section 1) |
| `filePutChunks` | the daemon takes `file_put_begin` / `_chunk` / `_finish` / `_cancel` |
| `filePut` | the daemon takes the one-shot `_acpmux/file_put` (one file in one request, kept for older clients) |
| `sendAttach` | the daemon saves a message's inline attachments (`acpmux send --attach`, `send_message`) |

A client sends by reference only to a daemon that lists `promptUploads`. Without it, the client
keeps the old inline path.

A daemon forwarding to a chat on a peer reads the same flags from the peer's `initialize` and
refuses, before anything is sent, what the peer would not take:

| call to a peer's chat | the peer must list | otherwise |
|---|---|---|
| `session/prompt` with an upload-ref block | `promptUploads` | `upload.unsupported` |
| `file_put_begin` with `forPrompt: true` | `promptUploads` | `upload.unsupported` |
| `session/prompt` with inline attachments | `sendAttach` | `attach.unsupported` |
| `file_put_status`, or `file_put_finish` with `sha256` | `uploadResume` | `filePut.unsupported` |
| `file_put_begin`, `file_put_chunk`, a binary data frame (sent on as `file_put_chunk`s) | `filePutChunks` (from #25803; before it, `file_put_chunk` needs `filePut`) | `filePut.unsupported` |
| `_acpmux/file_put` | `filePut` | `filePut.unsupported` |

## 1. Transport

The native side uses the WebSocket it already holds to its local daemon (the local listener,
`Origin::LocalApp`), or the unix socket.

- **Control calls** are JSON-RPC text frames: begin, status, finish, cancel (section 3).
- **Data, with `uploadFrames`:** each WebSocket **binary** frame is one JSON-RPC request with a raw
  payload:

  ```
  bytes 0..4    ASCII "AMUP"
  bytes 4..8    u32 big-endian H = the header's length
  bytes 8..8+H  UTF-8 JSON header:
                {"jsonrpc":"2.0","id":<id>,"method":"_acpmux/file_put_data",
                 "params":{"sessionId":"<chat>","uploadId":"<id>","offset":<u64>}}
  bytes 8+H..   the file's bytes [offset, offset+len), raw
  ```

  The daemon answers with an ordinary JSON-RPC text response that has the same `id`.

  - Frame size: 1 MiB of payload is recommended, and any length up to the connection's 64 MiB
    frame is taken. This limits a frame, not a file.
  - Frames may be pipelined at increasing offsets. A frame whose `offset` is not the upload's
    current end is refused with `upload.offset`.
  - A text message on the same connection is read only after every frame sent before it is
    written and answered, so a finish (or a prompt) sent right behind the last frame sees all of
    its bytes.
  - Only the local app's connection may send them. Any other connection's frame is answered
    with `filePut.remote`, never left unanswered.
- **Data, before `uploadFrames` and on the unix socket:**
  `_acpmux/file_put_chunk {sessionId, uploadId, offset, data}`, where `data` is base64 of at most
  512 KiB of bytes. It returns `{offset}`.
- **Chat on a peer:** send to your own daemon as for a local chat, naming the chat as in
  `session/prompt`. The daemon forwards begin, data, finish and cancel to the daemon that owns
  the chat, and that daemon writes the file. A peer without `promptUploads` refuses the reference
  with `upload.unsupported`, before anything is sent. A peer without `filePutChunks` refuses the
  begin and every data frame with `filePut.unsupported`.

## 1b. Bytes held by a page

This is page-to-native traffic, not a daemon method. Native pulls the bytes from the page. The
page never pushes them, and no byte travels on the page binding.

### The page

- It keeps each attachment's Blob or File (from a paste, a browser drop or `<input type=file>`)
  in `window.__cmuxUploadBlobs: Map<token, Blob>`. The token is a random string of at least 128
  bits.
- Before any upload, `transport.gesture` reserves a ticket for that exact `promptId` and
  `sessionId`. Native holds the ticket, reports progress on it and releases it.
- Over the binding the page sends one control call per file:

  ```json
  {"op": "uploads.begin",
   "params": {"token": "<random>", "name": "shot.png", "type": "image/png",
              "size": 812345, "sessionId": "<chat>", "promptId": "<prompt id>",
              "ticket": "<ticket>"}}
  ```

  Native refuses the call unless the ticket is live and reserved for this `promptId` and
  `sessionId`. `uploads.begin` answers `{uploadId}` as soon as `file_put_begin` returns, not
  after finish, so a page can show progress and cancel a large file. Nothing is keyed on the
  begin reply's timing.
- The final prompt redeems the ticket exactly once, in native, before native sends it to the
  daemon.
- A token names one upload attempt and gets exactly one terminal `uploads.state`. The page keeps
  the Blob until the prompt is accepted or the person removes the attachment.
- The prompt names the file by its `uploadId` (section 5), with no `owned`, so a refused
  prompt deletes nothing and a retry names the same finished uploads.
- Native begins with `forPrompt: true` and keeps each upload's `ownerToken` (section 3); every
  `file_put_cancel` below carries it.

### Retrying a failed attachment

- The page registers a **new** random token for the same Blob in `__cmuxUploadBlobs`, and calls
  `uploads.begin` again with the same `promptId` and the same still-live ticket.
- Only failed attachments are retried. A finished attachment's token and `uploadId` are reused.
- Native refuses `uploads.begin` for any token it has already seen, active or terminal. The page
  never reuses a token.
- A failed token stays failed: `uploads.status` on it keeps answering `"failed"`, and a late push
  for it never affects the new attempt.
- The prompt names only each attachment's current finished `uploadId`, never a failed
  attempt's.
- If a failed attempt has an `uploadId`, native calls `file_put_cancel` on it unless the daemon
  already ended it; otherwise the age sweep reaps it. A failed attempt is never resumed into the
  new token.
- The page may drop the old token's Blob-map entry once the new one is registered.
- There is no same-token retry, and no attempt generation in the carriers.

### Upload states (page and native)

- **Progress, information only:**
  `{"op":"uploads.progress","params":{token, uploadId, offset, size}}`. It is never terminal,
  including when `offset == size`.
- **Terminal state, the only source of truth:**
  `{"op":"uploads.state","params":{token, uploadId, state:"finished"|"failed"|"cancelled", size, error?:{code, message, host?, path?}}}`.
  Native pushes exactly one per token, and only after the daemon has answered
  `file_put_finish` (or after the failure or the cancel).
  - `"finished"`: `file_put_finish` answered success, so the upload is a finished upload of this
    chat and a reference to it resolves.
  - `"failed"`: carries the daemon's error. The only size failure is a full disk, with host and
    path (`upload.diskFull`, section 4).
  - `"cancelled"`: the person removed it, or `uploads.cancel` was called.
- **Status query**, for page reloads and races: `uploads.status {token}` answers the same params
  as `uploads.state`, with state `"uploading"` while it is not terminal. A page that lost a push
  asks this instead of guessing.
- **The prompt:** the page sends the final prompt only after every token for that `promptId` has
  reached `"finished"`. If any token is `"failed"`, the prompt stays queued with its attachments
  and shows the error; it is never sent with that reference. A retry re-uploads only the failed
  attachments, each under a new token, and keeps the same `promptId` and ticket.
- **Cancel:** `uploads.cancel {token}`. Native calls `file_put_cancel`, then pushes
  `uploads.state` `"cancelled"`.
- **Before `file_put_begin` is acknowledged:**
  - `uploads.status` and `uploads.state` carry `{token, size, state:"uploading"}` with no
    `uploadId` field at all: absent, not null and not `""`.
  - `uploadId` appears the moment the daemon assigns it, and never changes after that.
  - A failure or cancel before the begin ack is `{token, size, state:"failed"|"cancelled", error?}`
    with no `uploadId`. Native must not call `file_put_cancel` without an id.
  - After a cancel or failure before the ack, native keeps a cleanup-only handler for a late ack:
    the daemon may already have created the upload while its ack was delayed. If the ack later
    brings an `uploadId`, native calls `file_put_cancel` on it and does not change the page's
    already-terminal state. The page contract is unchanged.
  - `state:"finished"` always carries a non-empty, daemon-issued `uploadId`. A finished state
    without one is a native bug, and the page treats it as `"failed"` (code `upload.noId`).
  - The page never makes up an id or keys anything on one; it keys on `token`.
- **Carriers:** the state push is `cmux.agent.host.events {kind:"uploads.state", value:<params>}`.
  The calls are `cmux.agent.uploads.status` and `cmux.agent.uploads.cancel`.
- What native gets from the daemon for `"finished"`: `file_put_finish` answers
  `{path, size, uploadId}`. `size` is the finished file's byte count (with `uploadResume`;
  section 3).

### Native

Native reads the Blob over its own DevTools channel, inside the execution context the binding
call came from (main frame, PageHostTrust, as today). The steps:

1. Find the Blob: `Runtime.evaluate` of `window.__cmuxUploadBlobs.get(<token>)` with
   `returnByValue: false`. It refuses the call when the result is missing or not a Blob.
2. Read it in 1 MiB chunks:
   - Preferred: `IO.resolveBlob` gives a uuid, then `IO.read {handle: "blob:"+uuid, size: 1048576}`
     until `eof`, then `IO.close`.
   - Fallback: `Runtime.callFunctionOn` with `this.slice(o, o+n).arrayBuffer()`, returning the
     chunk as base64.
3. Send each chunk at the next offset. With `uploadFrames`, send one AMUP binary frame
   (section 1) per chunk. Until then, native's own daemon connection sends `file_put_chunk`
   calls of at most 512 KiB each. Either way, no attachment byte crosses the page binding.
   Read the next chunk only after the daemon acknowledges the previous one, or keep a fixed
   window of at most 4 in flight. Memory then stays at a few chunks whatever the file's size.
4. Finish with `file_put_finish`, then `Runtime.releaseObject`.

A file dropped on a native view, or picked with the native picker, is streamed by native straight
from its path. The page only gets `{token, name, type, size}` for its preview row.

### Security

- A token resolves only in the calling context's own registry. Native never reads by an objectId,
  a URL or a host path that the page names.
- A page can send only bytes it already holds.

### The ticket and the daemon

The ticket is page-to-native only, and the daemon contract does not change for it:

- The daemon never sees the ticket. Native checks it on `uploads.begin` and redeems it on the
  prompt. Native does not forward it in any daemon call. A daemon that got one would ignore it.
- The daemon does not bind an upload to a `promptId`. What it already enforces is enough:
  - only the local app's connection or the unix socket can upload (section 2);
  - a reference resolves only to a finished upload in the prompt's own chat (section 5);
  - a `promptId` runs once (section 7).
- Binding to the gesture is native's job: it is the one caller that holds the person's gesture.
- A retried prompt under the same `promptId` names the same `uploadId`s, and the daemon answers it
  as a duplicate (section 7). The ticket's single redemption therefore has nothing to add on the
  daemon side.

### What the daemon guarantees for this pacing

- Every data frame is written in order and answered after its bytes are on disk.
- Up to 4 frames in flight on one upload are taken in order.
- A frame that arrives out of order is refused with `upload.offset {offset}` and its bytes are
  dropped. The sender resumes at that offset.

## 2. What the daemon checks of the caller

- **Connection kind.** The daemon takes the `file_put_*` calls, data frames and references from:
  - the local app connection (LocalApp);
  - the unix socket;
  - a peer link forwarding for one of those.

  It refuses a Web-controlled connection (a remote web client, or a peer forwarding for one) with
  `filePut.remote` for uploads and `upload.remote` for references.
- **Chat binding.** An upload belongs to the chat whose `sessionId` began it. It lives in
  `<ACPMUX_HOME>/uploads/<session>/<uploadId>/<fileName>` (owner-only: 0700 folders, 0600 files).
  Every later call, and every reference to it, must name that same chat; another chat's upload
  is `upload.missing`.
- **Upload ids** are UUIDv7 values the daemon makes. They are unguessable and never name a path.
- **What the daemon does not check:** which window or gesture began an upload, and which person.
  The native endpoint binds those before it calls the daemon.

## 3. Calls

### Begin

`_acpmux/file_put_begin {sessionId, fileName, size, forPrompt?}` returns
`{uploadId, fileName, size}`, plus `ownerToken` with `forPrompt: true`.

- `fileName` must be a plain file name: no `/`, no leading `.`, no control or bidi characters.
  Otherwise it is refused with `filePut.name`.
- `size` is the exact byte count, any u64.
- `forPrompt: true` says the upload is for a prompt that names it. A chat on a peer without
  `promptUploads` is then refused here (`upload.unsupported`), before any byte is sent, rather
  than leaving a finished upload for a prompt the peer would refuse.
- `ownerToken` (from #25840) is a secret only the sender learns. Keep it natively for the life
  of the upload: only a cancel that carries it deletes a `forPrompt` upload (Cancel, below), and
  an `owned` reference carries it (section 5). Never hand it to a page.

### Data

Send data with `file_put_chunk` (section 1), or with `file_put_data` once `uploadFrames` exists.

- The answer's `offset` is the end of the bytes received so far. Use it for progress
  (`offset / size`) and to resume.
- The bytes are on disk before the answer comes.

### Status (with `uploadResume`)

`_acpmux/file_put_status {sessionId, uploadId}` returns
`{uploadId, fileName, size, offset, finished, path?}`.

- After a disconnect or a daemon restart, call status and resume at `offset`.
- Asking keeps an unfinished upload from the age sweep, as writing to it does.

### Finish

`_acpmux/file_put_finish {sessionId, uploadId, fileName, size}` returns `{path}`; with
`uploadResume`, `{path, size, uploadId}`, where `size` is the finished file's byte count. A
repeated finish answers the same.

- Allowed only once all `size` bytes have arrived.
- With `uploadResume`, an optional `sha256` (lowercase hex) is checked, and a mismatch is
  `upload.corrupt` with `data: {sha256}` (the hash the daemon computed):
  - On the first finish, the bytes received are not the sender's: the partial upload is removed,
    and the sender begins again.
  - On a repeated finish (the upload already finished), the finished file is checked and left as
    it is: the mismatch says the sender's hash is not that file's, and nothing is removed.

### Cancel

`_acpmux/file_put_cancel {sessionId, uploadId, ownerToken?}` returns `{}`, and it is idempotent.

- An upload begun with `forPrompt: true` (from #25840) is removed, finished or not, only by a
  cancel that carries its `ownerToken`; any other cancel removes nothing. So a sender that will
  not send the prompt naming an upload leaves nothing behind, and nobody else's cancel deletes
  it. A prompt that still names a removed upload is refused with `upload.missing`.
- Any other upload is removed while it is unfinished.

### How long uploads stay

- Finished uploads stay until the chat is deleted or the age sweep removes them
  (`uploadsMaxAgeDays`, default 30).
- An upload begun and never finished or cancelled (its sender's connection dropped, or a late
  begin ack nobody cancelled) is reaped by the same sweep. It deletes the upload's whole folder,
  `.part` and `.meta` included, once both the upload and its last use are older than
  `uploadsMaxAgeDays`. A write to its `.part` or a status call counts as use. So no part file
  is left orphaned past the age cap, and one still being written or resumed is never taken.
  Deleting the chat removes them at once. (`uploadsMaxAgeDays: 0` turns the sweep off, and then
  every upload stays until its chat is deleted.)
- Sending a prompt does not consume them, so a retried send never uploads again.

## 4. Errors

| reason | when |
|---|---|
| `upload.diskFull` (with `uploadResume`) | the receiving disk is full; `data: {host, path, needed?, free?, offset?}` |
| `upload.offset` (with `uploadResume`) | a chunk's or frame's offset is not the upload's end; `data: {offset}`, resume there |
| `filePut.pastSize` | bytes past the size given at begin; `data: {size}` |
| `filePut.name` | not a plain file name |
| `filePut.remote` | the call came from a Web-controlled connection |
| `filePut.unsupported` | the chat's peer runs a build without uploads |
| `upload.corrupt` (with `uploadResume`) | finish `sha256` mismatch, `data: {sha256}`; on a first finish the partial upload is removed (begin again), on a repeated finish the finished file is left (section 3) |

Today, an unknown upload, a wrong offset, or a finish before all bytes arrived returns a plain
`invalid_params` error with no `reason`. `uploadResume` gives these `upload.unknown`,
`upload.offset` and `upload.incomplete`.

A client retries every error except `filePut.name`, `filePut.remote` and disk-full. Before it
retries, it reads the upload's state (status, or its last acknowledged offset).

## 5. The upload-ref block in `session/prompt`

Each file is one block with no bytes, in the place the person put it. There are exactly two
shapes.

An image:

```json
{"type": "image", "name": "shot.png",
 "_meta": {"acpmux": {"upload": {"uploadId": "01a17a85-0041-7613-a731-292de6bd467a",
                                 "fileName": "shot.png"}}}}
```

Any other file, with a `uri` that is exactly `acpmux-upload:<uploadId>` so the block is valid ACP
before it is resolved:

```json
{"type": "resource_link", "uri": "acpmux-upload:01a17a85-0041-7613-a731-292de6bd467a",
 "name": "data.bin",
 "_meta": {"acpmux": {"upload": {"uploadId": "01a17a85-0041-7613-a731-292de6bd467a",
                                 "fileName": "data.bin"}}}}
```

- `fileName` must be the one given to `file_put_begin`.
- An image block has no `data` and no `uri`.
- The daemon sets `mimeType` from the file's bytes, so a sent `mimeType` is ignored.
- `inlineParts` display metadata works as before. Point its `blockIndex` at the reference block.
- `upload.owned: "<ownerToken>"` (from #25840) says the upload was made for this prompt alone;
  its value is the upload's `ownerToken` from begin, and any other value (`true` included)
  deletes nothing. If the prompt is refused before the chat takes it, the daemon deletes that
  upload. A prompt the chat takes, a duplicate and a held prompt keep it. `acpmux send --attach`
  sets it. Leave it out for an upload that another prompt or a retry may name, such as the
  app's uploads, which stay finished across retries: the app keeps the token natively and
  removes an attachment with a token-carrying `file_put_cancel`.

These are refused before anything is recorded:

| reason | when |
|---|---|
| `upload.invalid` | `uploadId` or `fileName` is missing; a `resource_link` whose `uri` is not `acpmux-upload:<the same uploadId>`; an image with a `uri`; any other block type |
| `upload.missing` | not a finished upload of this chat, or (at its turn) a waiting prompt's file was swept |
| `upload.unreadable` | the file is there but cannot be read (not a real folder, another hard link, permissions) |
| `upload.tooMany` | the prompt's links alone pass one message (15 MiB); send the files in more than one |
| `upload.remote` | the prompt came from a Web client |
| `upload.unsupported` | the chat is on a peer without `promptUploads` |

A queue edit (`_acpmux/queue_edit`) cannot carry a reference; it is refused with `attach.edit`.

## 6. What the agent and the transcript get

The daemon that runs the chat replaces each reference before anything reads the prompt:

- **An image that fits the model's input** goes inline as an `image` block with its bytes. The
  limits are 3.75 MiB an image (Claude's 5 MiB base64 limit) and 10 MiB of inline images per
  prompt, so the prompt stays one message on every hop. The transcript's `user_message.images`
  names it, as for any sent image.
- **Any other file, of any size, and any image past those limits** becomes
  `{"type": "resource_link", "uri": "file:///…/uploads/<chat>/<uploadId>/<name>", "name",
  "mimeType", "size"}`. It is never base64, so a 2 GB file adds a few hundred bytes to the prompt.
- **A model-sized copy** (`model_copies.rs`) goes next to the link to a PNG past those limits.
  It is made only when the prompt is written to the agent, after the prompt was accepted, so a
  busy chat still takes it at once:
  - It is scaled so its long edge fits the harness's model: 1568 px for Claude and any family the
    table does not name, 2048 px for Codex. It is scaled down again until it fits the inline image
    size and the prompt's inline room.
  - The copy is an inline `image`, with a line that names the original's path.
  - It is saved next to the upload as `.model-<edge>.png`, so a retry reuses it, and it is removed
    with the upload.
  - The transcript keeps the prompt as sent.
  - Another image type, or a PNG it cannot read, keeps only its link.
- **A context note** lists each file's path, type and size, and says which images are not shown
  inline. It is a text block marked `_meta.acpmux.context`, which the transcript hides. It lists
  as many files as fit the message with the prompt's other blocks; past that it ends with "and N
  more, each a resource_link in this message", since every file still has its link.

## 7. Idempotency

- A `promptId` runs once. After a reconnect or a daemon restart, send the same `promptId` with the
  same references again, with `_meta.acpmux.resend: true`.
- The daemon answers a duplicate from its ledger or its log with
  `_acpmux/prompt_accepted {duplicate: true}` and the first run's outcome. This works even after
  its uploads were swept.
- Treat a slow acceptance as "still sending": never fail it, and retry with the same `promptId`.
