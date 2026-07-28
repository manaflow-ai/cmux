public import Foundation

/// One validated binary terminal frame using the protocol v1 header.
public struct ShareBinaryFrame: Equatable, Sendable {
    /// Binary payload discriminator.
    public let kind: UInt8

    /// Wire workspace identifier.
    public let ws: String

    /// Wire pane identifier.
    public let pane: String

    /// Encoded render-grid payload.
    public let payload: Data

    /// Encodes `[kind u8][wsLen u8][ws utf8][paneLen u8][pane utf8][payload]`.
    ///
    /// The complete frame must remain strictly below 1 MiB. Validation occurs
    /// before allocating the output, so failure never returns a partial prefix.
    public static func encode(kind: UInt8, ws: String, pane: String, payload: Data) -> Data? {
        let workspaceBytes = Array(ws.utf8)
        let paneBytes = Array(pane.utf8)
        guard kind == ShareProtocolConstants.binaryKindGrid,
              isValidID(ws, encodedBytes: workspaceBytes),
              isValidID(pane, encodedBytes: paneBytes),
              workspaceBytes.count <= UInt8.max,
              paneBytes.count <= UInt8.max else {
            return nil
        }

        let headerByteCount = 3 + workspaceBytes.count + paneBytes.count
        guard payload.count < ShareProtocolConstants.binaryFrameByteLimit - headerByteCount else {
            return nil
        }

        var frame = Data(capacity: headerByteCount + payload.count)
        frame.append(kind)
        frame.append(UInt8(workspaceBytes.count))
        frame.append(contentsOf: workspaceBytes)
        frame.append(UInt8(paneBytes.count))
        frame.append(contentsOf: paneBytes)
        frame.append(payload)
        return frame
    }

    /// Decodes and validates a complete binary terminal frame.
    public static func decode(_ data: Data) -> ShareBinaryFrame? {
        guard data.count >= 3,
              data.count < ShareProtocolConstants.binaryFrameByteLimit,
              data[data.startIndex] == ShareProtocolConstants.binaryKindGrid else {
            return nil
        }

        let workspaceLengthIndex = data.startIndex + 1
        let workspaceLength = Int(data[workspaceLengthIndex])
        let workspaceStart = workspaceLengthIndex + 1
        let paneLengthIndex = workspaceStart + workspaceLength
        guard paneLengthIndex < data.endIndex else { return nil }

        let paneLength = Int(data[paneLengthIndex])
        let paneStart = paneLengthIndex + 1
        let payloadStart = paneStart + paneLength
        guard payloadStart <= data.endIndex,
              let workspace = String(
                  data: data[workspaceStart..<paneLengthIndex],
                  encoding: .utf8
              ),
              let pane = String(
                  data: data[paneStart..<payloadStart],
                  encoding: .utf8
              ) else {
            return nil
        }

        let workspaceBytes = Array(workspace.utf8)
        let paneBytes = Array(pane.utf8)
        guard workspaceBytes.count == workspaceLength,
              paneBytes.count == paneLength,
              isValidID(workspace, encodedBytes: workspaceBytes),
              isValidID(pane, encodedBytes: paneBytes) else {
            return nil
        }

        return ShareBinaryFrame(
            kind: ShareProtocolConstants.binaryKindGrid,
            ws: workspace,
            pane: pane,
            payload: Data(data[payloadStart...])
        )
    }

    private init(kind: UInt8, ws: String, pane: String, payload: Data) {
        self.kind = kind
        self.ws = ws
        self.pane = pane
        self.payload = payload
    }

    private static func isValidID(_ value: String, encodedBytes: [UInt8]) -> Bool {
        !encodedBytes.isEmpty
            && encodedBytes.count <= ShareProtocolConstants.maximumIDBytes
            && value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
    }
}
