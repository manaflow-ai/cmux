public import Foundation

/// Capability-gated pane I/O used by ``RemoteHerdrWindowMirror`` (tmux send-keys /
/// split-window / resize-pane / kill-pane / %output).
///
/// Implementations speak the provider socket only — never the `herdr` CLI.
public protocol RemoteHerdrPaneIO: Sendable {
    /// Forwards typed bytes to a Herdr pane (`pane.send` / `pane.send_keys`).
    func sendKeys(paneID: String, data: Data) async throws
    /// Splits a pane (`pane.split`).
    func splitPane(paneID: String, direction: RemoteHerdrSplitDirection) async throws
    /// Resizes a pane grid (`pane.resize`).
    func resizePane(paneID: String, cols: Int, rows: Int) async throws
    /// Closes a pane (`pane.close`). Host close still detaches without this.
    func closePane(paneID: String) async throws
    /// Reads current pane output (`pane.read`).
    func readPane(paneID: String, lines: Int) async throws -> Data
}

extension HerdrNestedTopologyClient: RemoteHerdrPaneIO {
    public func sendKeys(paneID: String, data: Data) async throws {
        // Prefer UTF-8 `text`; fall back to lossless base64 for non-UTF-8 bytes.
        let params: [String: Any]
        if let text = String(data: data, encoding: .utf8) {
            params = ["pane_id": paneID, "text": text]
        } else {
            params = ["pane_id": paneID, "data_base64": data.base64EncodedString()]
        }
        _ = try await performRequest(method: "pane.send", params: params)
    }

    public func splitPane(paneID: String, direction: RemoteHerdrSplitDirection) async throws {
        _ = try await performRequest(
            method: "pane.split",
            params: [
                "pane_id": paneID,
                "direction": direction.rawValue,
            ]
        )
    }

    public func resizePane(paneID: String, cols: Int, rows: Int) async throws {
        _ = try await performRequest(
            method: "pane.resize",
            params: [
                "pane_id": paneID,
                "cols": cols,
                "rows": rows,
            ]
        )
    }

    public func closePane(paneID: String) async throws {
        _ = try await performRequest(
            method: "pane.close",
            params: ["pane_id": paneID]
        )
    }

    public func readPane(paneID: String, lines: Int) async throws -> Data {
        let response = try await performRequest(
            method: "pane.read",
            params: [
                "pane_id": paneID,
                "lines": max(1, lines),
            ]
        )
        return try Self.paneReadData(from: response.result)
    }

    /// Extracts UTF-8 pane text from the documented protocol-17 `pane_text.text` field.
    static func paneReadData(from result: HerdrWireResult?) throws -> Data {
        guard case let .other(_, object) = result else {
            throw NestedTopologyProviderError.missingRequiredField("result.text")
        }
        guard case let .string(text)? = object["text"] else {
            throw NestedTopologyProviderError.missingRequiredField("result.text")
        }
        return Data(text.utf8)
    }
}
