# CmuxAppAttest

App Attest and DeviceCheck for the cmux apps (cx-ds09i): the platform half of
a device proof, behind two protocol seams.

- `DeviceAttesting`: key generation, attestation, assertions, DeviceCheck
  tokens. `AppleDeviceAttest(service: .shared, device: .current)` is the real
  service.
- `AttestKeyStore`: where the App Attest key id lives.
  `KeychainAttestKeyStore(service:account:)` keeps it in the login keychain.

Construct the concretes at the composition root and inject them. A stand-in
conforms to the protocols where no attestation exists:

```swift
struct NoAttest: DeviceAttesting {
    var isSupported: Bool { false }
    func generateKey() async throws -> String { throw DeviceAttestError.unsupported }
    func attestKey(_: String, clientDataHash _: Data) async throws -> Data { throw DeviceAttestError.unsupported }
    func generateAssertion(_: String, clientDataHash _: Data) async throws -> Data { throw DeviceAttestError.unsupported }
    func deviceCheckToken() async throws -> Data { throw DeviceAttestError.unsupported }
}
```
