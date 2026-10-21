# cmux-next-ios TestFlight readiness (cmux INTERNAL)

Date: 2026-10-13. Branch `feat-cnx-ios-testflight`. Nothing was uploaded or
distributed, and no App Store Connect setting was changed.

Target, checked on App Store Connect with the shared key (`cmux-shared Team Key`,
key `RUML2V4CW7`, `asc auth status --validate` = works):

| Field | Value |
| --- | --- |
| App record | **cmux INTERNAL**, app id `6791408425`, SKU `dev.cmux.app.internal` |
| Bundle id | `dev.cmux.app.internal` (portal id `JXV493637B`) |
| Capabilities on the bundle id | Push Notifications, Sign in with Apple (primary app consent), Time Sensitive Notifications, In-App Purchase |
| Profile | "cmux Internal Distribution" (`MUY2CLY8U6`), IOS_APP_STORE, active until 2027-08-26 |
| Latest upload | 1.0.6 (20261001183135), from the `ios/` app's INTERNAL lane |
| TestFlight groups | "cmux INTERNAL" (internal), "cmux family" (external) |

## How to build

```bash
cmux-next-ios/scripts/testflight-build.sh            # archive, export, verify, validate; no upload
cmux-next-ios/scripts/testflight-build.sh --upload   # only after every item below is done
```

The script checks the asc profile and the app record, picks a version and
build number above everything in cmux INTERNAL, checks the production Worker,
the shared-package sync, and the signing material, then archives the
`TestFlight` configuration from the committed SHA, exports an App Store IPA,
and checks the IPA: no DEBUG strings, production service address, version,
display name, icon, launch screen, privacy manifest, usage strings, and the
exact entitlement set. `altool --validate-app` runs last. `--upload` refuses
every bypass flag.

## Checklist

### Done

- [x] **Identity.** `TestFlight` configuration in `project.yml`: bundle `dev.cmux.app.internal`, display name "cmux INTERNAL" (the ASC record and the `ios/` lane's name), `CMUX_MOBILE_PRODUCTION CMUX_MOBILE_TESTFLIGHT`, -O, no DEBUG, production Stack project `9790718f-…`.
- [x] **Versioning.** `MARKETING_VERSION` 1.1.0 in `project.yml`, above 1.0.6. The build number is a 14-digit UTC timestamp, like the `ios/` lane, so it stays monotonic across both. The script refuses a lower version or build number.
- [x] **Service address as a build setting.** `CMUX_MOBILE_PROD_API_BASE` (default `https://cmux-mobile-api-prod.debussy.workers.dev`, from `backend/wrangler.jsonc` env `prod`) feeds `TestFlight` and `Release`. Release no longer ships with no service address (audit blocker 14). `check-production-binary.sh --shipping` rejects a `-dev` or local address.
- [x] **Entitlements** (`App/CmuxMobileApp-TestFlight.entitlements`): `aps-environment=production`, `com.apple.developer.applesignin=[Default]`, `keychain-access-groups=[7WLXT3NR37.dev.cmux.app.internal]`. All three are in the profile. Time-sensitive notifications are in the profile but left out: the app sends none. Audit blocker 10 (no Sign in with Apple entitlement) is fixed for this build.
- [x] **Privacy manifest** (`App/PrivacyInfo.xcprivacy`, bundled): no tracking; collected email, name, user id and device id (linked, app functionality); required-reason APIs UserDefaults `CA92.1`, file timestamps `C617.1` (log rotation, Rust `fstat`), system boot time `35F9.1` (`systemUptime` for tap timing), active keyboards `54BD.1` (emoji field). Found by source search and the binary's imports; no disk-space API.
- [x] **Usage strings**: camera, photo library, photo library add, microphone, and local network (new: the link dials the Mac's LAN address). No Face ID string: nothing calls LocalAuthentication. No speech recognition. No background modes: nothing uses them.
- [x] **Encryption.** `ITSAppUsesNonExemptEncryption = YES` (reasoning below).
- [x] **App icon and launch screen**: the Icon Composer `AppIcon.icon` compiles to 1024 px phone and pad icons in `Assets.car`; `UILaunchScreen` uses `LaunchBackground` and `LaunchMark`.
- [x] **Archive.** `testflight-build.sh --unsigned --allow-backend-down --allow-package-drift` at `dbb0bed1d5` archived 1.1.0 (20261014034250) with Xcode 27.0 (27A266a, iOS 27.0 SDK), arm64, minimum iOS 26.0. Every app check passed, including `check-production-binary.sh --shipping`. Output: `~/cmux-mobile-builds/20261014-dbb0bed1d5-testflight/`.
- [x] **Metadata draft**: `verify/testflight-metadata.md` (What to Test, test information, review notes, export compliance answers). Not submitted.

### Blocked

- [ ] **Distribution signing identity.** "cmux Internal Distribution" authorizes five certificates (two Apple Distribution, three iPhone Distribution, serials `3ADCDF4E…`, `591D27F5…`, `13E58F81…`, `5FAD24AB…`, `470A7316…`). None of their private keys is on this Mac or on `mini-cmuxs-mac-mini-2`, and no 1Password item for one was visible. The `ios/` lane signs on CI from the GitHub secret `IOS_DISTRIBUTION_CERTIFICATE_BASE64`. Until an identity is in the login keychain, the script stops before export, so there is no signed IPA and no Apple validation yet. Choose one:
  - Import the existing distribution `.p12` (from whoever holds the CI secret) into this Mac's login keychain, and store it in a 1Password team vault so the next agent can use it.
  - Allow creating a new Apple Distribution certificate through the shared key, with its private key made on this Mac, plus a new App Store profile for `dev.cmux.app.internal` with that certificate. The existing profile and CI stay untouched.
- [ ] **Production Worker.** `https://cmux-mobile-api-prod.debussy.workers.dev/v1/health` returns 404 (Cloudflare 1042: not deployed). A build made now signs in to an empty app. The prodinfra agent is deploying it. If it lands on another URL (the audit asks for a custom domain), run with `CMUX_MOBILE_PROD_API_BASE=<url>` or change `project.yml`. The script requires `/v1/health` to list only the production Stack project.

### Needs the user

- [ ] **Two apps feeding cmux INTERNAL.** `.github/workflows/ios-testflight.yml` uploads the `ios/` app to cmux INTERNAL every 20 minutes and assigns each build to the "cmux INTERNAL" group. A cmux-next-ios build replaces that app on testers' phones (same bundle id). The `ios/` lane stamps 1.0.x, so testers stay on cmux-next-ios 1.1.0, but new `ios/` builds keep landing beside it. Decide: pause the scheduled INTERNAL lane before the first cmux-next-ios upload, or let both upload.
- [ ] **Version 1.1.0.** Confirm, or pass `--marketing-version` (it must be at least 1.0.6).
- [ ] **Sign in with Apple in the production Stack project.** The app uses the Stack SDK's native flow: the Apple identity token, whose audience is `dev.cmux.app.internal`, goes to `POST /api/v1/auth/oauth/callback/apple/native` on project `9790718f-14cd-4f7e-824d-eaf527a82b82`. The `ios/` app's INTERNAL builds use the same bundle id, project and code path (`CmuxAuthRuntime` `signInWithApple`), so Stack should already accept it. This could not be checked without a signed build. If the first TestFlight sign-in fails with an Apple sign-in error: in the Stack dashboard, open project `9790718f…`, then Auth Methods, then Apple, and add `dev.cmux.app.internal` to its bundle ids (team `7WLXT3NR37`). No code change is needed.
- [ ] **Shared-package drift.** `Packages/iOS/CmuxTabsKit` differs from `origin/feat-cmux-next-tabs-kit` (0ea4df4e, card corner and close button). The cmux-next-ios owner should sync it (`scripts/check-tabskit-sync.sh` prints the command) before the upload build; the script refuses `--upload` with drift.
- [ ] **Export compliance.** Confirm the answers in `verify/testflight-metadata.md`. Without an encryption declaration, App Store Connect asks them on each build, and the build cannot go to testers until they are answered. To skip that, create one declaration in App Store Connect (no documents needed for standard algorithms) and add its `ITSEncryptionExportComplianceCode` to `project.yml`.
- [ ] **External group.** "cmux family" is external, so its builds need Beta App Review and the demo account in the metadata draft. Use `--internal-only` if this build must never reach it.

### Not TestFlight blockers (App Store or later)

- Push is entitled but unused: the app never registers for remote notifications and the backend has no APNs sender (audit blocker 12). Setup and Settings still promise notifications.
- "Require Face ID" is saved but never enforced (audit blocker 11). Whoever implements it adds `NSFaceIDUsageDescription`.
- Account deletion (App Store 5.1.1(v), audit blocker 3) and the App Privacy label, which must match `PrivacyInfo.xcprivacy`, are needed before App Store review.
- Same bundle as the `ios/` app: an update keeps that app's container and keychain group. cmux-next-ios uses its own `mobile.*` defaults keys. If the old app left a production Stack session under the same keychain service, the tester may already be signed in.
- No associated domains or URL schemes: the bundle id has none, and the app handles no links. Email sign-in uses the code, and invite links open the website (audit invites row).

## Encryption: why YES, and why no documents

cmux-next-ios encrypts user data with code that is not Apple's:

- WireGuard through `boringtun`: Curve25519, ChaCha20-Poly1305, BLAKE2s.
- WebRTC through `webrtc-rs`: DTLS and SRTP with AES.
- TLS 1.3 through `rustls` and `ring` for its HTTPS client.

So the "only Apple OS encryption, or HTTPS only" exemption does not apply, and
`ITSAppUsesNonExemptEncryption` is `YES` (the `ios/` app declares `NO`). Every
algorithm is a published standard (IETF), and the app is a mass-market consumer
app. That makes it EAR Category 5 Part 2, mass-market under §740.17(b)(1): no
CCATS, no documents for Apple, and, since the March 2021 EAR change, no annual
self-classification report for this kind of item. In App Store Connect: uses
encryption yes, exempt no, proprietary algorithms no, standard algorithms yes.
This is the standard reading of Apple's export-compliance guide. It is not legal
advice; confirm with counsel before the App Store release.
