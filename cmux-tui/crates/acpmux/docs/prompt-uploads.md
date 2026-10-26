# Prompt uploads: files of any size, sent by reference

The contract between a client that sends files with a prompt and the acpmux daemon. A typical
client is the cmux app's native upload worker.

Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE".

- No size or count cap: no limit per file, per prompt, or on the number of files.
- No base64 in the page binding: file bytes travel as binary frames on a connection the host owns.
- The prompt names the uploads and stays a few hundred bytes.
- The only failure about size is a full disk on the receiving host, and that error names the host
  and path.

Capability flags, in `initialize` result `_meta.acpmux.features`:

| flag | means |
|---|---|
| `promptUploads` | the daemon resolves upload-ref blocks in `session/prompt` (#25730) |
| `uploadFrames` | the daemon takes binary data frames and `_acpmux/file_put_status`, and has no upload size cap |

A client sends by reference only to a daemon that lists both flags. Without them, it keeps the old
inline path.

## 1. Transport and endpoint

Use the same WebSocket the app already holds to its local daemon: the app's `AcpmuxPaneSocket`,
the local listener, `Origin::LocalApp`. Nothing new is opened.

- **Control calls** are ordinary JSON-RPC text frames and carry no file bytes: begin, status,
  finish, cancel (section 3).
- **Data** goes in WebSocket **binary** frames. Each binary frame is one JSON-RPC request with a
  raw payload:

  ```
  bytes 0..4    ASCII "AMUP"
  bytes 4..8    u32 big-endian H = the header's length
  bytes 8..8+H  UTF-8 JSON header:
                {"jsonrpc":"2.0","id":<id>,"method":"_acpmux/file_put_data",
                 "params":{"sessionId":"<chat>","uploadId":"<id>","offset":<u64>}}
  bytes 8+H..   the file's bytes [offset, offset+len), raw
  ```

  The daemon answers with an ordinary JSON-RPC text response that has the same `id` (section 3).

- **Frame size:** 1 MiB of payload is recommended. Any length up to the connection's 64 MiB frame
  is taken. This is a frame size, not a file cap.
- **Pipelining:** a client may have several frames in flight, at increasing offsets on one upload.
  The daemon writes them in order. A frame whose `offset` is not the upload's current end is
  refused with `upload.offset` (section 4), and its bytes are dropped.
- **Other transports:**
  - **Unix socket (CLI):** a text-only stream. It keeps `_acpmux/file_put_chunk`
    `{sessionId, uploadId, offset, data: base64}` (at most 512 KiB decoded per chunk), with the
    same answers.
  - **Chat on a peer:** the client sends to its own daemon as for a local chat, naming the chat as
    it does in `session/prompt`. The daemon forwards each frame to the daemon that owns the chat.
    Progress and resume work end to end.

## 2. Auth and the owner and chat binding

- **Who may send data:** binary frames and the `file_put_*` calls are taken from:
  - the local app connection (LocalApp token, the person's connection);
  - the unix socket;
  - a peer link forwarding for one of those.
- **Who is refused:** a Web connection, or a peer forwarding for a Web client, gets `filePut.remote`.
- **Binding:** `file_put_begin` binds the upload to its `sessionId` and to the class of connection
  that began it. Data, status, finish and cancel must name the same `sessionId`. The upload lives
  in `<ACPMUX_HOME>/uploads/<session>/<uploadId>/`, owner-only (0700 folders, 0600 files), and a
  reference resolves only inside its own chat's folder.
- **Upload ids** are UUIDv7 values made by the daemon. They are not guessable, and they cannot
  name a path.

## 3. Calls and fields

### Begin

`_acpmux/file_put_begin {sessionId, fileName, size}` returns
`{uploadId, fileName, size, offset: 0}`.

- `fileName` must be a plain file name: no `/`, no leading `.`, no control or bidi characters.
- `size` is the file's exact byte count, any u64.
- The daemon checks free space on its disk. Less than `size` free is refused with
  `upload.diskFull` (section 4).

### Data

`_acpmux/file_put_data` (a binary frame) returns `{uploadId, offset, size}`.

- `offset` is the new end of the bytes received so far. It is the progress value: draw
  `offset / size`.
- The bytes are written to disk before the answer. A frame the daemon has answered survives a
  daemon restart.

### Status (resume)

`_acpmux/file_put_status {sessionId, uploadId}` returns
`{uploadId, fileName, size, offset, finished, path?}`.

- After a disconnect, a daemon restart or any error, call status and resume data at the returned
  `offset`.
- `finished: true` comes with `path`: the upload was finished already.

### Finish

`_acpmux/file_put_finish {sessionId, uploadId, fileName, size, sha256?}` returns
`{uploadId, path, size}`.

- Finish is allowed only once `offset == size`.
- With `sha256` (lowercase hex), the daemon hashes the file and refuses a mismatch with
  `upload.corrupt`. It then keeps the bytes, so status shows `offset == size` and the client
  re-sends from 0 after a cancel.
- Finish is idempotent: a second finish of a finished upload returns the same `path`.

### Cancel

`_acpmux/file_put_cancel {sessionId, uploadId}` returns `{}`.

- It removes the partial file. It is idempotent.

### Cleanup

- Finished uploads stay until the chat is deleted or the age sweep runs (`uploadsMaxAgeDays`,
  default 30 days).
- A send does not consume them, so a retried send never needs to upload again.

## 4. Errors

Every error is a JSON-RPC error with `data.reason`:

| reason | when | data |
|---|---|---|
| `upload.diskFull` | the receiving disk has no room (at begin, from free space; or on a write, from ENOSPC) | `{host, path, needed?, free?, offset?}` |
| `upload.offset` | a frame's offset is not the upload's end | `{offset}`: resume there |
| `upload.unknown` | no such upload in this chat (cancelled, swept, another chat's) | |
| `upload.pastSize` | bytes past the size given at begin | `{size}` |
| `upload.incomplete` | finish before `offset == size` | `{offset, size}` |
| `upload.corrupt` | finish with a `sha256` that does not match | `{sha256}`: the daemon's |
| `filePut.name` | not a plain file name | |
| `filePut.remote` | from a Web connection | |
| `upload.unsupported` | a peer on an older build | |

A client retries every error except `upload.diskFull`, `filePut.name` and `filePut.remote`, after
`file_put_status`.

## 5. The upload-ref block in `session/prompt`

Each file is one prompt block with no bytes, in the place the person put it:

```json
{"type": "image", "name": "shot.png",
 "_meta": {"acpmux": {"upload": {"uploadId": "<uuidv7>", "fileName": "shot.png"}}}}
```

Use `"type": "image"` for an image and `"type": "resource_link"` for any other file. The daemon
also takes `resource`. The `fileName` must be the one given to `file_put_begin`. Other `_meta`
keys of the block are ignored, and `inlineParts` work as before.

Refusals of a reference:

| reason | when |
|---|---|
| `upload.missing` | not a finished upload of this chat |
| `upload.invalid` | `uploadId` or `fileName` missing |
| `upload.remote` | the prompt came from a Web client |
| `upload.unsupported` | the chat is on a peer without `promptUploads` |

A queue edit (`_acpmux/queue_edit`) cannot carry a reference (`attach.edit`).

## 6. What the agent and the transcript get

The daemon that runs the chat replaces each reference before anything reads the prompt:

- **An image that fits the model's input** (and the prompt's inline room, so the prompt stays one
  message on every hop) goes inline as an `image` block. Its `mimeType` comes from the bytes.
  - The transcript's `user_message.images` names it, as for any sent image.
  - #25730 sizes: at most 3.75 MiB an image (Claude's 5 MiB base64 limit) and 10 MiB of inline
    images a prompt.
- **A model-sized copy (follow-up PR):** an image past those limits gets a model-sized copy,
  downscaled to the harness's limit (one table per harness), inline instead. The original's path
  is in the note. Until that lands, such an image goes as a link.
- **Any other file, of any size:** a `resource_link`
  `{uri: "file:///…/uploads/<chat>/<uploadId>/<name>", name, mimeType, size}`. It is never
  base64, so a 2 GB file costs the prompt a few hundred bytes.
- **A context note**, a text block marked `_meta.acpmux.context`, lists every file's path, type
  and size. It also says which images were not shown inline. The transcript hides it.

## 7. Idempotency

- A `promptId` runs once. Send the same `promptId` with the same references again, with
  `_meta.acpmux.resend: true` after a reconnect or a daemon restart.
- The daemon answers a duplicate from its ledger or its log, with
  `_acpmux/prompt_accepted {duplicate: true}` and the first run's outcome. This holds even after
  the uploads are swept.
- Treat a slow acceptance as still sending: never fail it, and retry with the same `promptId`.
