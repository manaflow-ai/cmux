# CmuxSSHNative

Native libssh client boundary for cmux iOS and macOS remote sessions.

The package owns only the C ABI bridge and Swift transport adapter. Account
authorization, host-key approval, and lazy credential ordering live in
`CmuxRemoteConnections`. The adapter never reads SSH config, known-host files,
agent sockets, or credentials from disk.

`Artifacts/CmuxSSHBackend.xcframework` is generated from the pinned libssh
0.12.2 and Mbed TLS 3.6.7 sources by `scripts/build-libssh-ios.sh`. It contains
arm64 simulator, iPhoneOS, and macOS slices with server, GSSAPI, FIDO2,
PKCS#11, and local command execution support disabled. The artifact receipt
records source and archive hashes. Protocol runtime and physical-device
verification remain separate acceptance steps.
