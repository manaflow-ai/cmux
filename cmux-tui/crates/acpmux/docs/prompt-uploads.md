# Prompt uploads: files of any size, sent by reference

The contract between a client that sends files with a prompt and the acpmux daemon. A typical
client is the cmux app's native upload worker.

Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE".

- No size or count cap: no limit per file, per prompt, or on the number of files.
- No base64 in the page binding: file bytes go from the app's native side to the daemon, never
  through the page.
- The prompt names the uploads and stays a few hundred bytes.
- The only failure about size is a full disk on the receiving host, and that error names the host
  and path.

Who owns what: the daemon owns this API (upload calls, the reference resolver, peer forwarding,
feature flags). The native app owns its own host-authenticated endpoint, origin and gesture
binding, and calls this API over its daemon connection.

## 0. What exists at which head

| part | status |
|---|---|
| `file_put_begin` / `_chunk` (base64, at most 512 KiB a chunk) / `_finish` / `_cancel`, no size cap | landed, #25730 |
| upload-ref blocks in `session/prompt` (section 5), what the agent gets (section 6), dedupe (section 7) | landed, #25730 |
| `promptUploads` feature flag | landed, #25730 |
| `_acpmux/file_put_status`, finish `sha256`, the `upload.*` error reasons, `upload.diskFull` | #25793, flag `uploadResume` |
| binary data frames `_acpmux/file_put_data` on the app's WebSocket, peer chats included | #25803, flag `uploadFrames` |
| `acpmux send --attach` and `send_message` send any size and number by reference (no 8 MiB / 10 MiB / 16-file refusal), begin `forPrompt` | #25840 |

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

A client sends by reference only to a daemon that lists `promptUploads`. Without it, the client
keeps the old inline path.

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
  `sessionId`. It answers `{uploadId}` once `file_put_begin` returns it, then pushes progress
  `{token, uploadId, offset, size}` to the page as data is acknowledged.
- The final prompt redeems the ticket exactly once, in native, before native sends it to the
  daemon.
- A retry keeps the token. The page keeps the Blob until the prompt is accepted or the person
  removes the attachment.
- The prompt names the file by its `uploadId` (section 5).

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
`{uploadId, fileName, size}`.

- `fileName` must be a plain file name: no `/`, no leading `.`, no control or bidi characters.
  Otherwise it is refused with `filePut.name`.
- `size` is the exact byte count, any u64.
- `forPrompt: true` says the upload is for a prompt that names it. A chat on a peer without
  `promptUploads` is then refused here (`upload.unsupported`), before any byte is sent, rather
  than leaving a finished upload for a prompt the peer would refuse.

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

`_acpmux/file_put_finish {sessionId, uploadId, fileName, size}` returns `{path}`.

- Allowed only once all `size` bytes have arrived.
- With `uploadResume`, an optional `sha256` (lowercase hex) is checked, and a mismatch is
  `upload.corrupt`.

### Cancel

`_acpmux/file_put_cancel {sessionId, uploadId}` returns `{}`.

- It removes the partial file, and it is idempotent.

### How long uploads stay

- Finished uploads stay until the chat is deleted or the age sweep removes them
  (`uploadsMaxAgeDays`, default 30).
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
| `upload.corrupt` (with `uploadResume`) | finish `sha256` mismatch; the upload is removed, begin again |

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
  A follow-up PR adds a model-sized copy of a large image (downscaled to the harness's limit, from
  one table per harness) inline, next to the link to the original.
- **A context note** lists every file's path, type and size, and says which images are not shown
  inline. It is a text block marked `_meta.acpmux.context`, which the transcript hides.

## 7. Idempotency

- A `promptId` runs once. After a reconnect or a daemon restart, send the same `promptId` with the
  same references again, with `_meta.acpmux.resend: true`.
- The daemon answers a duplicate from its ledger or its log with
  `_acpmux/prompt_accepted {duplicate: true}` and the first run's outcome. This works even after
  its uploads were swept.
- Treat a slow acceptance as "still sending": never fail it, and retry with the same `promptId`.
