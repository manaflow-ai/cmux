public import Foundation

extension CloudMachineIO {
    /// One Rust preview operation. The account credential goes on stdin, never argv;
    /// a missing or failed child never falls back to repeating a share over HTTP.
    @concurrent func preview(_ request: [String: any Sendable]) async throws -> CloudMachinePreviewShare {
        let input = try JSONSerialization.data(withJSONObject: request)
        let output: Data
        do {
            output = try await Self.run(binary, arguments: ["cloud", "preview-account"], stdin: input,
                                        timeout: .seconds(35), work: work)
        } catch is NoAnswer {
            throw CloudAPIError.transport("The preview helper did not answer; the share may have completed.")
        }
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }) else {
            throw CloudAPIError.decoding("machine.preview_missing_answer")
        }
        struct Reply: Decodable {
            var ok: Bool
            var value: CloudMachinePreviewShare?
        }
        let data = Data(line)
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: data) } catch {
            throw CloudAPIError.decoding("machine.preview_invalid_answer")
        }
        guard reply.ok else { throw CloudAPIError.from(status: 0, data: data, headerCode: nil) }
        guard let value = reply.value else { throw CloudAPIError.decoding("machine.preview_missing_answer") }
        return value
    }
}
