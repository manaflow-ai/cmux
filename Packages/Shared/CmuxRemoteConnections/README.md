# CmuxRemoteConnections

Shared Swift connection settings and encrypted-record primitives for native
mobile and desktop clients. This package has no app, UI, network, or filesystem
dependency.

Current behavior:

- Immutable profiles validate both direct construction and JSON decoding.
- Credentials are references in profile data; plaintext material does not
  conform to Codable and redacts ordinary/debug/mirror descriptions.
- AES-256-GCM record encryption binds owner, vault, record, payload domain,
  key epoch, revision, deletion status, and format version.
- Received ciphertext has bounded size. Opening it requires independently
  supplied expected context, not identity values from an unverified envelope.

This is not a complete encrypted vault. Keychain storage, signing, device
enrollment, recovery, key rotation, membership, rollback protection, encrypted
profile persistence, SSH, and the app integration remain unimplemented. Never
advertise these helpers as proof of secure cross-device synchronization.

## Use

```swift
import CmuxRemoteConnections
import CryptoKit
import Foundation

let profile = try MobileRemoteProfile(
    id: UUID().uuidString, host: "dev.example.com", username: "alice"
)
let context = try MobileRemoteVaultContext(
    accountID: "verified-owner", vaultID: UUID(), recordID: UUID(),
    kind: .profile, keyEpoch: 1, revision: 1
)
let key = SymmetricKey(size: .bits256) // Obtain from the approved vault owner.
let cipher = MobileRemoteVaultCipher()
let sealed = try cipher.encrypt(JSONEncoder().encode(profile), context: context, key: key)
let opened = try cipher.decrypt(sealed, context: context, key: key)
let restored = try JSONDecoder().decode(MobileRemoteProfile.self, from: opened)
```

Consumers must enforce transport limits before parsing JSON, maintain trusted
revision and membership state, authenticate envelope authors, and never log
decrypted records. Software secrets can occupy Swift value copies; these types
do not promise zeroization of all copies. Keychain controls and active-session
lock policy must be enforced by the eventual credential service.

## Verification

Run `swift test --package-path Packages/Shared/CmuxRemoteConnections` from the
repository root. Tests cover round-trip use, profile decoder rejection,
cross-context substitution, ciphertext corruption, deletion authentication,
wrong/short keys, and record limits. They do not establish iOS runtime or
end-to-end connection behavior.

The known-answer test opens an independently generated Python cryptography
50.0.1 AESGCM vector using public synthetic key/nonce bytes. This pins the
length-prefixed associated-data format for other platform implementations.
