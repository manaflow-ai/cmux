import Foundation
@preconcurrency import CmuxIrohC

protocol CmxIrohSecretKeyStoring: Sendable {
    func loadSecretKey() throws -> Data?
    func saveSecretKey(_ key: Data) throws
}

enum CmxIrohSecretKeyStoreError: Error, Equatable, Sendable {
    case invalidLength(Int)
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
}

struct CmxIrohSecretKeyProvider: Sendable {
    let store: any CmxIrohSecretKeyStoring
    let generate: @Sendable () throws -> Data

    func secretKey() throws -> Data {
        if let existing = try store.loadSecretKey() {
            try validate(existing)
            return existing
        }
        let generated = try generate()
        try validate(generated)
        try store.saveSecretKey(generated)
        return generated
    }

    private func validate(_ data: Data) throws {
        guard data.count == Int(CMUX_IROH_SECRET_KEY_LEN) else {
            throw CmxIrohSecretKeyStoreError.invalidLength(data.count)
        }
    }
}
