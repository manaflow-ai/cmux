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
            _ = try await client.post("/v1/home/attachments/multipart/complete", [
                "conversation": .string(file.conversation.rawValue), "slot": .string(slot), "parts": .array(parts)
            ], effect: .mutation)
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

    /// Sends a large original in bounded Worker requests. The server verifies
    /// each piece, then streams the ordered objects into one hash-checked file.
    private func putMultipart(_ answer: HomeWireJSON, from file: URL) async throws -> [HomeWireJSON] {
        guard let url = answer["upload_url"].string.flatMap(URL.init(string:)) else { throw HomeRejection.invalid("attachment.bad_answer") }
        let size = Int(answer["part_size"].double ?? 0)
        guard size > 0 else { throw HomeRejection.invalid("attachment.bad_answer") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var parts: [HomeWireJSON] = []
        var number = 1
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: size), !data.isEmpty else { break }
            var request = URLRequest(url: url)
            request.httpMethod = answer["method"].string ?? "PUT"
            for (name, value) in answer["headers"].object ?? [:] {
                if let text = value.string { request.setValue(text, forHTTPHeaderField: name) }
            }
            request.setValue(String(number), forHTTPHeaderField: "x-cmux-part-number")
            request.setValue(String(data.count), forHTTPHeaderField: "content-length")
            request.httpBody = data
            let http = client.http
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

    private static func derived(_ image: AttachmentDerivedImage) -> HomeWireJSON {
        ["sha256": .string(image.hash), "byte_count": .number(Double(image.byteCount)), "mime_type": .string(image.mimeType)]
    }
}
