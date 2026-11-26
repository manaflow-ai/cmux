public import Foundation
import UniformTypeIdentifiers

// WireHomeSource's attachments over the owner's attachment routes
// (backend/apps/api/src/home-attachments.ts): intent, bounded PUT/multipart
// upload, and signed download URLs.
extension WireHomeSource {
    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        try Self.requireConversationID(file.conversation)
        let ref = file.ref
        var intent: [String: HomeWireJSON] = [
            "conversation": .string(file.conversation.rawValue), "sha256": .string(ref.hash), "multipart": .bool(true),
            "byte_count": .number(Double(ref.byteCount)), "mime_type": .string(ref.mimeType), "name": .string(ref.name),
        ]
        if let width = ref.width { intent["width"] = .number(Double(width)) }
        if let height = ref.height { intent["height"] = .number(Double(height)) }
        if let duration = ref.durationMs { intent["duration_ms"] = .number(Double(duration)) }
        if let poster = ref.poster, file.posterURL != nil { intent["poster"] = Self.derived(poster) }
        if let preview = ref.preview, file.previewURL != nil { intent["preview"] = Self.derived(preview) }
        let value = try await client.post("/v1/home/attachments/intent", .object(intent), effect: .mutation)["value"]
        if value["state"].string == "exists" {
            file.progress(1)
            return ref
        }
        guard value["state"].string == "upload" else { throw HomeRejection.invalid("attachment.bad_answer") }
        // A declared poster or preview goes first: the owner refuses the bytes until it is stored.
        for (field, local) in [("poster_upload", file.posterURL), ("preview_upload", file.previewURL)] where value[field].object != nil {
            guard let local else { throw HomeRejection.invalid("attachment.bad_answer") }
            let reply = try await put(value[field], from: local, toWorker: true)
            // 409: stored by an earlier attempt of this slot.
            if reply.status != 409 { _ = try HomeWireClient.check(reply, effect: .mutation) }
        }
        if value["mode"].string == "multipart" {
            let parts = try await putMultipart(value, from: file.fileURL)
            guard let slot = value["slot"].string else { throw HomeRejection.invalid("attachment.bad_answer") }
            let complete: HomeWireJSON = [
                "conversation": .string(file.conversation.rawValue), "slot": .string(slot), "parts": .array(parts)
            ]
            // Direct parts never passed the server: it hashes the joined file back one bounded step per call.
            while try await client.post("/v1/home/attachments/multipart/complete", complete, effect: .mutation)["value"]["state"].string == "verifying" {
                try Task.checkCancellation()
            }
        } else {
            let presigned = value["mode"].string == "presigned"
            let reply = try await put(value, from: file.fileURL, toWorker: !presigned)
            if presigned {
            // 412: a retried presigned PUT whose first attempt landed (`if-none-match: *`).
            guard (200...299).contains(reply.status) || reply.status == 412 else {
                throw reply.status >= 500 ? HomeRejection.indeterminate : HomeRejection.invalid("attachment.upload_refused")
            }
            guard let slot = value["slot"].string else { throw HomeRejection.invalid("attachment.bad_answer") }
            _ = try await client.post("/v1/home/attachments/commit",
                                      ["conversation": .string(file.conversation.rawValue), "slot": .string(slot)], effect: .mutation)
            } else {
                _ = try HomeWireClient.check(reply, effect: .mutation)
            }
        }
        file.progress(1)
        return ref
    }

    public func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        try Self.requireConversationID(location.conversation)
        try FileManager.default.createDirectory(at: fetchDirectory, withIntermediateDirectories: true)
        switch variant {
        case .original:
            return try await download(ref, at: location, variant: nil, mimeType: ref.mimeType)
        case .poster:
            guard let poster = ref.poster else { throw HomeRejection.invalid("no_poster") }
            return try await download(ref, at: location, variant: "poster", mimeType: poster.mimeType)
        case .preview:
            guard let preview = ref.preview else { throw HomeRejection.invalid("no_preview") }
            return try await download(ref, at: location, variant: "preview", mimeType: preview.mimeType)
        case .thumbnail(let maxPixel):
            // No thumbnail service: downsample the preview, the image or the video's poster here.
            let target = fetchDirectory.appendingPathComponent("\(ref.hash)-thumb-\(maxPixel).jpg")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            let source: AttachmentVariant
            if ref.preview != nil, maxPixel <= HomeAttachmentPolicy.previewMaxPixel {
                source = .preview
            } else if ref.mimeType.hasPrefix("image/") {
                source = .original
            } else if ref.poster != nil {
                source = .poster
            } else {
                throw HomeRejection.invalid("no_thumbnail")
            }
            let image = try await fetch(ref, at: location, variant: source)
            let data = try AttachmentMedia.thumbnailJPEG(of: image, maxPixel: maxPixel)
            try Task.checkCancellation()
            try data.write(to: target, options: .atomic)
            return target
        }
    }

    /// One variant's bytes from a signed URL (`POST /v1/home/attachments/url`),
    /// kept by hash and variant: a second fetch reads the file, a cancelled
    /// one leaves nothing behind.
    private func download(_ ref: AttachmentRef, at location: AttachmentLocation, variant: String?, mimeType: String) async throws -> URL {
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
        let target = fetchDirectory.appendingPathComponent("\(ref.hash)-\(variant ?? "original")\(ext)")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        var body: [String: HomeWireJSON] = ["conversation": .string(location.conversation.rawValue), "hash": .string(ref.hash)]
        if let message = location.message, let part = location.partIndex {
            body["message_id"] = .string(message.rawValue)
            body["part_index"] = .number(Double(part))
        }
        if let variant { body["variant"] = .string(variant) }
        let answer: HomeWireJSON
        do {
            answer = try await client.post("/v1/home/attachments/url", .object(body), effect: .read)
        } catch HomeRejection.invalid(let code) where code == "attachment.no_poster" || code == "attachment.no_preview" {
            throw HomeRejection.invalid(String(code.dropFirst("attachment.".count)))
        }
        guard let url = answer["value"]["url"].string.flatMap(URL.init(string:)) else { throw HomeRejection.invalid("attachment.bad_answer") }
        let (status, file) = try await client.http.download(URLRequest(url: url))
        guard let file else {
            throw status >= 500 || status == 0 ? HomeRejection.ownerUnreachable : HomeRejection.invalid("attachment.not_found")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    /// The PUT an intent answer describes (`method`, `upload_url`, `headers`).
    /// Only a Worker URL gets the auth header; a presigned bucket URL is
    /// signed by its query and must not carry one.
    private func put(_ answer: HomeWireJSON, from file: URL, toWorker: Bool) async throws -> HomeWireHTTPReply {
        guard let url = answer["upload_url"].string.flatMap(URL.init(string:)) else { throw HomeRejection.invalid("attachment.bad_answer") }
        var request = URLRequest(url: url)
        request.httpMethod = answer["method"].string ?? "PUT"
        for (name, value) in answer["headers"].object ?? [:] {
            if let text = value.string { request.setValue(text, forHTTPHeaderField: name) }
        }
        let http = client.http
        if toWorker {
            return try await client.exchange(request, effect: .mutation) { try await http.upload($0, fromFile: file) }
        }
        do {
            return try await http.upload(request, fromFile: file)
        } catch {
            throw HomeRejection.indeterminate
        }
    }

    /// Sends a large original in bounded requests, one per part. `transport`
    /// "worker" (or absent): each part is a PUT through the server, which
    /// hashes it. "direct" (parts larger than the server's request limit): a
    /// POST asks for the part's presigned R2 URL, the part goes there with no
    /// auth header, and R2's ETag is kept for the completion.
    private func putMultipart(_ answer: HomeWireJSON, from file: URL) async throws -> [HomeWireJSON] {
        guard let url = answer["upload_url"].string.flatMap(URL.init(string:)) else { throw HomeRejection.invalid("attachment.bad_answer") }
        let size = answer["part_size"].int ?? 0
        guard size > 0 else { throw HomeRejection.invalid("attachment.bad_answer") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        if answer["transport"].string == "direct" {
            return try await putDirectParts(answer, url: url, size: size, from: handle)
        }
        var parts: [HomeWireJSON] = []
        var number = 1
        while true {
            try Task.checkCancellation()
            let data = try Self.readPart(size: size) { try handle.read(upToCount: $0) }
            guard !data.isEmpty else { break }
            var request = URLRequest(url: url)
            request.httpMethod = answer["method"].string ?? "PUT"
            for (name, value) in answer["headers"].object ?? [:] {
                if let text = value.string { request.setValue(text, forHTTPHeaderField: name) }
            }
            request.setValue(String(number), forHTTPHeaderField: "x-cmux-part-number")
            let http = client.http
            request.setValue(String(data.count), forHTTPHeaderField: "content-length")
            request.httpBody = data
            let reply = try await client.exchange(request, effect: .mutation) { try await http.send($0) }
            let body = try HomeWireClient.check(reply, effect: .mutation)
            guard let part = body["value"]["part_number"].int, part == number,
                  let count = body["value"]["byte_count"].int, count == data.count else {
                throw HomeRejection.invalid("attachment.bad_answer")
            }
            var value: [String: HomeWireJSON] = ["part_number": .number(Double(number)), "byte_count": .number(Double(data.count))]
            if let etag = body["value"]["etag"].string { value["etag"] = .string(etag) }
            parts.append(.object(value))
            number += 1
        }
        guard !parts.isEmpty else { throw HomeRejection.invalid("attachment.bad_answer") }
        return parts
    }

    /// One part of `size` bytes, or the rest of the file: `read` may return fewer bytes than asked
    /// before the end (a short read), so it is called until the part is full or it returns nothing.
    static func readPart(size: Int, _ read: (Int) throws -> Data?) throws -> Data {
        var part = Data()
        while part.count < size {
            guard let next = try read(size - part.count), !next.isEmpty else { break }
            part.append(next)
        }
        return part
    }

    /// The direct parts of the file behind `handle`, in order. A direct part is larger than the
    /// server's request limit (hundreds of MiB or more), so it never sits in memory: each is
    /// copied to its own temporary file in bounded chunks and uploaded from that file, which is
    /// removed once its upload returns.
    private func putDirectParts(_ answer: HomeWireJSON, url: URL, size: Int, from handle: FileHandle) async throws -> [HomeWireJSON] {
        let total = try handle.seekToEnd()
        var parts: [HomeWireJSON] = []
        var number = 1
        var offset: UInt64 = 0
        while offset < total {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            for (name, value) in answer["headers"].object ?? [:] {
                if let text = value.string { request.setValue(text, forHTTPHeaderField: name) }
            }
            request.setValue(String(number), forHTTPHeaderField: "x-cmux-part-number")
            let (piece, count) = try Self.partFile(handle, offset: offset, length: Int(min(UInt64(size), total - offset)))
            defer { try? FileManager.default.removeItem(at: piece) }
            guard count > 0 else { break }
            parts.append(try await putDirectPart(number, file: piece, count: count, asking: request))
            offset += UInt64(count)
            number += 1
        }
        guard !parts.isEmpty else { throw HomeRejection.invalid("attachment.bad_answer") }
        return parts
    }

    /// Copies `length` bytes at `offset` of `handle` into a new temporary file, `chunk` bytes at a
    /// time, and answers it with the bytes copied (fewer only at the end of the file). Memory stays
    /// at one chunk whatever the part's size; the caller removes the file.
    static func partFile(_ handle: FileHandle, offset: UInt64, length: Int, chunk: Int = 8 << 20) throws -> (URL, Int) {
        let piece = FileManager.default.temporaryDirectory.appendingPathComponent("home-part-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: piece.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let out = try FileHandle(forWritingTo: piece)
            defer { try? out.close() }
            try handle.seek(toOffset: offset)
            var copied = 0
            while copied < length {
                let next = try readPart(size: min(chunk, length - copied)) { try handle.read(upToCount: $0) }
                guard !next.isEmpty else { break }
                try out.write(contentsOf: next)
                copied += next.count
            }
            return (piece, copied)
        } catch {
            try? FileManager.default.removeItem(at: piece)
            throw error
        }
    }

    /// One direct part: the server signs a URL for part `number`, then the
    /// part's file goes straight to the bucket and its ETag names the part.
    private func putDirectPart(_ number: Int, file: URL, count: Int, asking: URLRequest) async throws -> HomeWireJSON {
        var ask = asking
        ask.httpMethod = "POST"
        let http = client.http
        let signed = try HomeWireClient.check(try await client.exchange(ask, effect: .mutation) { try await http.send($0) }, effect: .mutation)["value"]
        guard signed["part_number"].int == number, let url = signed["url"].string.flatMap(URL.init(string:)) else {
            throw HomeRejection.invalid("attachment.bad_answer")
        }
        var request = URLRequest(url: url)
        request.httpMethod = signed["method"].string ?? "PUT"
        for (name, value) in signed["headers"].object ?? [:] {
            if let text = value.string { request.setValue(text, forHTTPHeaderField: name) }
        }
        let reply: HomeWireHTTPReply
        do {
            reply = try await http.upload(request, fromFile: file)
        } catch {
            throw HomeRejection.indeterminate
        }
        guard (200...299).contains(reply.status), let etag = reply.etag else {
            throw reply.status >= 500 ? HomeRejection.indeterminate : HomeRejection.invalid("attachment.upload_refused")
        }
        return ["part_number": .number(Double(number)), "byte_count": .number(Double(count)), "etag": .string(etag)]
    }

    private static func derived(_ image: AttachmentDerivedImage) -> HomeWireJSON {
        ["sha256": .string(image.hash), "byte_count": .number(Double(image.byteCount)), "mime_type": .string(image.mimeType)]
    }
}
