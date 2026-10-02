public import Foundation
import Synchronization

/// One import run's Keychain reads: each "<Name> Safe Storage" item is read
/// once, so cookies and passwords from the same browser cost the user one
/// macOS prompt, and a Deny is not asked again. The keys live in
/// `SecretBytes` and are zeroed when the run drops this object; never keep
/// it past the run.
public final class OneReadSafeStorage: SafeStorageKeyProviding {
    private let source: any SafeStorageKeyProviding
    private let read = Mutex<[String: Result<SecretBytes, CookieImportError>]>([:])

    public init(_ source: any SafeStorageKeyProviding) {
        self.source = source
    }

    public func password(service: String) throws(CookieImportError) -> Data {
        // Held across the read: a second caller waits for the one prompt rather than raising its own.
        let result = read.withLock { reads in
            if let earlier = reads[service] { return earlier }
            let result: Result<SecretBytes, CookieImportError>
            do {
                result = .success(SecretBytes(copying: try source.password(service: service)))
            } catch {
                result = .failure(error)
            }
            reads[service] = result
            return result
        }
        return try result.get().withUnsafeBytes { Data($0) }
    }
}
