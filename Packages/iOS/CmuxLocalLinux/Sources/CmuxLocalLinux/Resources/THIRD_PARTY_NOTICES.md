# CmuxLocalLinux third-party notices

This resource is shipped with the local Linux package so an installed iOS
build carries the notices for the embedded kernel, libarchive, and Alpine
fakefs. The complete GPL and iSH license texts, plus the libarchive notice, are
included beside this file. Other Alpine package licenses are identified below
with their upstream source links.

## iSH

The iSH user-mode x86 kernel is vendored from the Manaflow fork at
`vendor/ish`. The exact source revision is the Git submodule revision recorded
by the parent repository. iSH is licensed under the GNU General Public License
version 3. Contributions after iSH commit
`0e3a4144f93135c4fd618c8397d2cfd87194f69f` are additionally licensed under the
GNU General Public License version 2. The complete texts are shipped with
this package as `iSH-LICENSE.md` and `iSH-LICENSE.IOS`, and remain available
in the source tree as `vendor/ish/LICENSE.md` and `vendor/ish/LICENSE.IOS`.

iSH's iOS notice says:

> The iSH developers are aware that the terms of service that apply to apps
> distributed via Apple's App Store services may conflict with rights granted
> under the iSH license, the GNU GPLv2 or v3. The copyright holders of the iSH
> app do not wish this conflict to prevent the otherwise-compliant distribution
> of derived apps via the App Store. Therefore, we have committed not to pursue
> any license violation that results solely from the conflict between the GNU
> GPLv2 or v3 and the Apple App Store terms of service. In other words, as long
> as you comply with the GPL in all other respects, including its requirements
> to provide users with source code and the text of the license, we will not
> object to your distribution of the iSH app through the App Store.

The full texts are `iSH-LICENSE.md`, `iSH-LICENSE.IOS`, `GPL-3.0.txt`, and
`GPL-2.0.txt`.

## libarchive

The iSH archive reader is built from the vendored libarchive source at
`vendor/ish/deps/libarchive`. Its copyright and license notice is
`libarchive-COPYING`, which is included in this package resource.

## Alpine Linux root filesystem

The bundled archive is an Alpine Linux 3.24.1 x86 root filesystem tarball. It
is converted into iSH's fakefs layout on the device by `cmux_ish_import_rootfs`
(iSH's `fakefs_import`). The source URL, archive digest, and exact package
versions are in `alpine-rootfs.json`. The package licenses reported by Alpine's
`lib/apk/db/installed` are:

| Package family | License(s) |
| --- | --- |
| alpine-baselayout, apk-tools, libapk, scanelf, busybox, ssl_client | GPL-2.0-only |
| alpine-keys, alpine-release, musl | MIT |
| ca-certificates-bundle | MPL-2.0 and MIT |
| libcrypto3, libssl3 | Apache-2.0 |
| musl-utils | MIT, BSD-2-Clause, and GPL-2.0-or-later |
| zlib | Zlib |

The corresponding license texts and source links are maintained by the Alpine
Linux project and the upstream projects listed in the package metadata. The
repository-level `THIRD_PARTY_LICENSES.md` records the same provenance for
source distributions. `SOURCE-OFFER.md` explains how to obtain the exact
corresponding source for this build.
