import CmuxNextAgentPane
import Foundation

/// `chat.upload.begin` requests as the page sends them, decoded the way the bridge decodes every
/// page request (``AgentPaneRequest/init(body:)``), past the former 1 GiB decoder limit: a lone
/// file, a batch's first file, and a small first file whose batch names a later file past it.
enum DecodedStagedBegins {
    /// Each begin's params for a file of `size` bytes, with the staged begin they must decode into.
    static func cases(size: Int) -> [(params: [String: Any], begin: AgentPaneUploadStageRequest)] {
        let pastFormerLimit = (1 << 30) + 1, small = 1024 * 1024
        let batch = [AgentPaneUploadBatchEntry(name: "big.bin", size: size), AgentPaneUploadBatchEntry(name: "next.bin", size: pastFormerLimit)]
        let smallFirst = [AgentPaneUploadBatchEntry(name: "small.bin", size: small), AgentPaneUploadBatchEntry(name: "big.bin", size: size)]
        let manifest = { (entries: [AgentPaneUploadBatchEntry]) -> [[String: Any]] in entries.map { ["name": $0.name, "size": $0.size] } }
        return [
            (["name": "big.bin", "size": size], .begin(name: "big.bin", size: size, batchToken: nil, batch: nil)),
            (["name": "big.bin", "size": size, "batch": manifest(batch)], .begin(name: "big.bin", size: size, batchToken: nil, batch: batch)),
            (["name": "small.bin", "size": small, "batch": manifest(smallFirst)],
             .begin(name: "small.bin", size: small, batchToken: nil, batch: smallFirst)),
        ]
    }

    /// `params` decoded as the page's `chat.upload.begin`: its staged begin, or nil when the decoder refuses it.
    static func decode(_ params: [String: Any]) -> AgentPaneUploadStageRequest? {
        guard case .uploadStage(let stage) = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": params]) else { return nil }
        return stage
    }
}
