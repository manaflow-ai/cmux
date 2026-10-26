public import Foundation

/// The App's upload of files the person dropped or pasted into a chat: it replies as the page's
/// `chat.upload` call (``AgentPaneReply``).
public typealias AgentPaneUploader = @MainActor (_ files: [AgentPaneUpload]) async -> [String: Any]

public nonisolated struct AgentPaneUploadBatchEntry: Sendable, Equatable {
    public let name: String
    public let size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// One step of a file the page streams in chunks (`chat.upload.begin`, `.chunk`, `.finish`,
/// `.cancel`). A file has any size (Leo, 2026-10-24: "we shouldn't have this limit"): its
/// destination refuses it only when its disk lacks room. A chunk keeps the page's base64 text, so
/// the main thread never decodes it: the stager decodes and writes it off the main thread, or
/// sends the text on as it is.
public nonisolated enum AgentPaneUploadStageRequest: Sendable, Equatable {
    case begin(name: String, size: Int, batchToken: String?, batch: [AgentPaneUploadBatchEntry]?)
    case chunk(token: String, offset: Int, base64: String)
    case finish(token: String)
    case cancel(token: String)

    /// The most bytes one chunk decodes to (the page's 512 KiB slices).
    public static let maximumChunkBytes = 512 * 1024

    /// The bytes padded base64 `text` decodes to, read from its length and padding with no decode
    /// (O(1) for the page's string); nil for a length no padded base64 has.
    public static func decodedLength(_ text: String) -> Int? {
        let units = text.utf16
        guard units.count % 4 == 0 else { return nil }
        let pad = units.reversed().prefix(2).prefix(while: { $0 == 0x3D }).count
        return units.count / 4 * 3 - pad
    }

    /// The most files one batch names.
    public static let maximumBatchFiles = 64
}

public typealias AgentPaneUploadStager = @MainActor (_ request: AgentPaneUploadStageRequest, _ sessionId: String?) async -> [String: Any]

/// A file the person dropped or pasted into a chat that the composer can't attach, for the App to
/// send to the chat's Cloud machine (`chat.upload {files: [{name, data}]}`, cmuxterm-hq#1874
/// slice 6). The page reads the bytes (it never learns a dropped file's path); the host takes them
/// only for a chat the App uploads for (``AgentPaneModel/onUpload``) and only with a real gesture in
/// the pane: a key or click, or a native file drop on the page (page script can make neither). Its
/// description and mirror never show the bytes or the name.
public nonisolated struct AgentPaneUpload: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public var description: String { "<upload \(data.count) bytes>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// The whole-file `chat.upload` call (an older page) holds every file in memory: one GiB in
    /// all. A file of any size streams in chunks (``AgentPaneUploadStageRequest``); Cloud uploads
    /// keep their smaller policy in ``CloudUploads``.
    public static let maximumFileBytes = 1 * 1024 * 1024 * 1024
    public static let maximumTotalBytes = 1 * 1024 * 1024 * 1024
    public static let maximumPeerFileBytes = maximumFileBytes

    /// The files of `chat.upload`'s params, nil when they break the contract: one or more files,
    /// each with a name a folder holds as one file and base64 bytes, at most
    /// ``maximumFileBytes`` each and ``maximumTotalBytes`` in all.
    static func files(_ params: [String: Any]?) -> [AgentPaneUpload]? {
        guard let params, Set(params.keys) == ["files"], let list = params["files"] as? [[String: Any]],
              !list.isEmpty else { return nil }
        var files: [AgentPaneUpload] = []
        var total = 0
        for item in list {
            guard Set(item.keys) == ["name", "data"], let name = item["name"] as? String, isFileName(name),
                  let text = item["data"] as? String, text.utf8.count <= (maximumFileBytes / 3 + 1) * 4,
                  let data = Data(base64Encoded: text), data.count <= maximumFileBytes else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(data.count)
            total = overflow ? Int.max : sum
            guard total <= maximumTotalBytes else { return nil }
            files.append(AgentPaneUpload(name: name, data: data))
        }
        return files
    }

    /// A name a folder holds as one plain file: 1 to 255 UTF-8 bytes, not a dot file (nor `.` or
    /// `..`), no `/`, and no control or bidirectional formatting character.
    static func isFileName(_ name: String) -> Bool {
        guard (1...255).contains(name.utf8.count), !name.hasPrefix("."), !name.contains("/") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value)
                || (0x202a...0x202e).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) || scalar.value == 0x200e || scalar.value == 0x200f)
        }
    }

    /// The reply to the page's upload: only for a chat the App uploads for (asked before the gesture
    /// is used, so another chat's paste keeps its gesture), then only with a real gesture.
    @MainActor static func respond(_ files: [AgentPaneUpload], in model: AgentPaneModel) async -> [String: Any] {
        guard let uploader = model.onUpload?() else { return AgentPaneModel.unsupported("chat.upload") }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        return await uploader(files)
    }
}
