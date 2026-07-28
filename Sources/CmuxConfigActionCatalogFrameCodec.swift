import Foundation

struct CmuxConfigActionCatalogFrameCodec: Sendable {
    static let shared = CmuxConfigActionCatalogFrameCodec()
    static let magic = Data("CMUXCFG1".utf8)
    static let maximumPathBytes = 64 << 10

    func encode(
        _ response: CmuxConfigActionCatalogRawReadResponse,
        maximumConfigBytes: Int
    ) -> Data? {
        let pathData = response.localPath.map { Data($0.utf8) } ?? Data()
        guard pathData.count <= Self.maximumPathBytes,
              (response.localPath == nil) == (response.local == nil),
              validFile(response.local, maximumConfigBytes: maximumConfigBytes),
              validFile(response.global, maximumConfigBytes: maximumConfigBytes) else {
            return nil
        }

        var frame = Self.magic
        appendField(
            status: response.localPath == nil ? .missing : .data,
            payload: pathData,
            to: &frame
        )
        let local = response.local ?? CmuxConfigActionCatalogRawFile(
            status: .missing,
            data: Data()
        )
        appendField(status: local.status, payload: local.data, to: &frame)
        appendField(status: response.global.status, payload: response.global.data, to: &frame)
        return frame
    }

    func decode(
        _ frame: Data,
        maximumConfigBytes: Int
    ) -> CmuxConfigActionCatalogRawReadResponse? {
        let bytes = [UInt8](frame)
        let magicBytes = [UInt8](Self.magic)
        guard bytes.count >= magicBytes.count,
              Array(bytes.prefix(magicBytes.count)) == magicBytes else {
            return nil
        }
        var cursor = magicBytes.count
        guard let pathField = decodeField(
            bytes,
            cursor: &cursor,
            maximumPayloadBytes: Self.maximumPathBytes
        ),
        let localField = decodeField(
            bytes,
            cursor: &cursor,
            maximumPayloadBytes: maximumConfigBytes
        ),
        let globalField = decodeField(
            bytes,
            cursor: &cursor,
            maximumPayloadBytes: maximumConfigBytes
        ), cursor == bytes.count else {
            return nil
        }

        let localPath: String?
        switch pathField.status {
        case .missing:
            guard pathField.payload.isEmpty else { return nil }
            localPath = nil
        case .data:
            guard !pathField.payload.isEmpty,
                  let path = String(data: pathField.payload, encoding: .utf8) else {
                return nil
            }
            localPath = path
        case .unreadable, .tooLarge:
            return nil
        }

        guard let local = decodedFile(localField),
              let global = decodedFile(globalField),
              localPath != nil || local.status == .missing else {
            return nil
        }
        return CmuxConfigActionCatalogRawReadResponse(
            localPath: localPath,
            local: localPath == nil ? nil : local,
            global: global
        )
    }

    private func validFile(
        _ file: CmuxConfigActionCatalogRawFile?,
        maximumConfigBytes: Int
    ) -> Bool {
        guard let file else { return true }
        switch file.status {
        case .data:
            return file.data.count <= maximumConfigBytes
        case .missing, .unreadable, .tooLarge:
            return file.data.isEmpty
        }
    }

    private func decodedFile(_ field: Field) -> CmuxConfigActionCatalogRawFile? {
        switch field.status {
        case .data:
            return CmuxConfigActionCatalogRawFile(status: .data, data: field.payload)
        case .missing, .unreadable, .tooLarge:
            guard field.payload.isEmpty else { return nil }
            return CmuxConfigActionCatalogRawFile(status: field.status, data: Data())
        }
    }

    private func appendField(
        status: CmuxConfigActionCatalogRawFileStatus,
        payload: Data,
        to frame: inout Data
    ) {
        frame.append(status.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
    }

    private func decodeField(
        _ bytes: [UInt8],
        cursor: inout Int,
        maximumPayloadBytes: Int
    ) -> Field? {
        guard cursor <= bytes.count - 5,
              let status = CmuxConfigActionCatalogRawFileStatus(rawValue: bytes[cursor]) else {
            return nil
        }
        let length = bytes[(cursor + 1)..<(cursor + 5)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        cursor += 5
        guard length <= UInt32(maximumPayloadBytes),
              Int(length) <= bytes.count - cursor else {
            return nil
        }
        let payload = Data(bytes[cursor..<(cursor + Int(length))])
        cursor += Int(length)
        return Field(status: status, payload: payload)
    }
}
