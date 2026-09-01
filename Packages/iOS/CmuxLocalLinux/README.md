# CmuxLocalLinux

`CmuxLocalLinux` runs an Alpine Linux userland on an iPhone or iPad through
the vendored iSH user-mode x86 kernel. It exposes the kernel's PTY byte stream
to the existing cmux iOS terminal surface. No paired Mac is required.

## Build inputs

The package links `IshKernel.xcframework`, a generated static xcframework at
the repository root. It is intentionally not committed because it contains
large architecture-specific archives. Build it before opening the iOS
workspace or resolving Swift packages:

```sh
git submodule update --init --recursive vendor/ish
./scripts/verify-ish-ios-artifacts.sh --build
```

The script emits arm64 device and arm64 simulator slices. Set
`CMUX_ISH_DEVICE_ONLY=1` only when a simulator slice is not needed. A missing
or stale xcframework must fail the build rather than silently disabling the
local shell.

The verifier provisions Meson and Ninja when a build is required. It uses the
installed Homebrew formulae when available and a private, pinned Python
environment otherwise. `./scripts/build-ish-ios.sh` invokes the same helper for
direct builds, so a clean checkout has one deterministic tool setup path.

The Alpine fakefs archive is a checked-in product resource at
`Sources/CmuxLocalLinux/Resources/alpine-rootfs.tar.gz`. Its SHA-256 and
package manifest are recorded in `Resources/alpine-rootfs.json`; update both
files together when changing the rootfs.

## Tests

The package tests cover the local scrollback/replay contract without booting an
iSH kernel. After building the xcframework, run the package tests with SwiftPM:

```sh
swift test --package-path Packages/iOS/CmuxLocalLinux --disable-sandbox --parallel
```

## Licensing

iSH is GPLv3, with GPLv2 relicensing for later contributions. Its
`LICENSE.IOS` App Store grant applies to this derived app when the GPL source
and license text remain available. The Alpine rootfs contains the packages
listed in `Resources/alpine-rootfs.json`; their licenses and source offer are
documented in `Resources/THIRD_PARTY_NOTICES.md`, `Resources/SOURCE-OFFER.md`,
and the repository-level `THIRD_PARTY_LICENSES.md`. The package carries the
complete GPLv2, GPLv3, iSH, and libarchive notice texts used by the shipped
binary. The remaining Alpine license identifiers point to their upstream
notices in `THIRD_PARTY_NOTICES.md`.
