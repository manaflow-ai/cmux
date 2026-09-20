# CmuxRemoteConnections

Shared Swift connection settings, encrypted local persistence, and record
encryption for native mobile and desktop clients. It has no app or UI dependency.

Current behavior:

- Immutable profiles validate both direct construction and JSON decoding.
- Profile and credential references use opaque UUIDs, independent of addresses.
- Credentials are references in profile data; plaintext material does not
  conform to Codable and redacts ordinary/debug/mirror descriptions.
- AES-256-GCM record encryption binds owner, vault, record, payload domain,
  key epoch, revision, deletion status, and format version.
- Received ciphertext has bounded size. Opening it requires independently
  supplied expected context, not identity values from an unverified envelope.
- The SQLite profile store encrypts private metadata, isolates account/vault
  scopes, authenticates deleted records, and verifies the existing key before
  permitting writes. Corruption, wrong keys, and unsupported schemas are errors.
- The account gate fails closed until the app publishes a verified cmux session;
  it is required by every future SSH, Mosh, ET, and cmux-protocol owner.
- Signed vault revisions bind an authorized device identity and exact sealed
  ciphertext to independently supplied ownership and revision context. Personal
  and team recovery policy keeps organization recovery out of personal vaults.
- The merge policy accepts only current-epoch revisions from authenticated
  owner/editor members, rejects stale and same-revision conflicts, and retains
  authenticated tombstones. Its anti-rollback state still needs durable sync
  storage and membership-manifest verification.
- Signed X25519 key envelopes transfer one vault epoch key from an approved
  device to an exact device or organization recovery recipient. The server can
  relay ciphertext but cannot substitute the recipient or decrypt the key.
- The SSH boundary requires account authentication and host-key approval before
  it invokes a lazy credential source. Mosh and ET adapters must reuse this
  bootstrap ordering while implementing their own session protocols.

This is not a complete encrypted vault. Signing, device enrollment, recovery,
key rotation, membership, whole-database rollback protection, SSH, account
authentication integration, sync, and the app integration remain unimplemented.
The Keychain adapter is storage-only and its signed iOS integration suite still
requires the hosted iOS runner. Never advertise these helpers as proof of
secure cross-device synchronization.

## Use

```swift
import CmuxRemoteConnections
import CryptoKit
import Foundation

let profile = try MobileRemoteProfile(
    id: UUID(), host: "dev.example.com", username: "alice"
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

The local repository takes an explicit private database URL, authenticated
owner,
vault ID, and caller-supplied key. It never invents a replacement key when stored
data fails authentication. A key-check marker prevents a new profile from being
added under the wrong key even when that profile ID does not exist yet.

`lock()` drops the repository's key reference. The composition owner must also
clear decrypted UI state and terminate or lock live sessions. Neither operation
can revoke plaintext already copied elsewhere. Records are limited to 64 KiB
per profile and 8 MiB across a vault, with at most 1024 retained rows including
deletions. The account/vault row identity and revisions remain visible on disk.
Whole-database rollback detection requires additional trusted synchronization
state; the local record cipher alone does not provide it.

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

Persistence tests use fresh temporary SQLite files and exercise reopen,
concurrent repository owners, cancellation, write rollback, wrong-key writes,
scope isolation, altered ciphertext/deletion flags, and schema rejection.
The hosted `Remote connection package tests` workflow runs the package in a
unique iOS Simulator through `ios/RemoteConnectionsTests.xcworkspace`. This is
package-level iOS evidence, not the complete terminal-app verification.

The known-answer test opens an independently generated Python cryptography
50.0.1 AESGCM vector using public synthetic key/nonce bytes. This pins the
length-prefixed associated-data format for other platform implementations.
