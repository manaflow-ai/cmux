# App Review gate (before Apple sees it)

The app App Review judges is the NEXT iOS app, `cmux-next-ios` (CmuxMobileApp).
Its public build is project.yml's `AppStore` configuration, bundle `com.cmux.app`,
which replaces the classic app as an update.

`.github/workflows/ios-review-gate.yml` answers "would Apple accept this build
right now?" with one ranked list, in the run summary and in the
`app-review-gate-report` artifact. Nothing is submitted until it is empty.

## How the production pipeline calls it

The gate judges one feat-cmux-next commit. The pipeline passes it the full SHA
it builds and refuses to submit unless the gate is green on that SHA:

```yaml
  review-gate:
    needs: app-source            # resolves the feat-cmux-next SHA it builds
    permissions:
      contents: read
      actions: read              # the lint downloads the IPA artifact
    uses: manaflow-ai/cmux/.github/workflows/ios-review-gate.yml@feat-cmux-next
    with:
      ref: ${{ needs.app-source.outputs.sha }}
      lane: appstore
      ipa_artifact_name: ""      # or the artifact holding the exported .ipa
    secrets: inherit
```

The upload job then `needs: [app-source, review-gate]` with `if: always() && ...`
(upload runs either way), and before `--submit` it requires
`needs.review-gate.result == 'success'` and
`needs.review-gate.outputs.sha == needs.app-source.outputs.sha`. The gate's
`blocking` output is the number of blocking findings.

## Checks

| Check | Where | Catches |
| --- | --- | --- |
| Reviewer path | `cmux-next-ios/UITests/AppReviewGateUITests.swift` (`CmuxMobileAppUITests`, scheme `CmuxMobileApp`, Debug with the mock account, built after `xcodegen generate`), on iPhone, iPad (dark mode, the iPhone app in compatibility mode) and iPhone Duo | sign-in with Sign in with Apple first and every provider signing in, onboarding's way on without a Mac, Home and its tabs, Chief opening and a sent message getting a reply (mock Chief), Delete Account asking first (never confirmed), Scan with the camera denied, the largest text size, and size-class changes |
| Dead-control walk | same file, `walkControls` | a tap that changes nothing (2.1(a), 2026-11-07) on sign-in, onboarding, Home, Settings (top and bottom) and Account; an already-selected option is skipped; sign out, Delete Account and Remove This iPhone are not tapped |
| Guideline lint | `cmux-next-ios/scripts/app_review_gate.py lint` | the AppStore configuration (bundle `com.cmux.app`), metadata and every URL, account deletion, Sign in with Apple (source, shipping configuration, entitlements, binary), outside purchase links, purpose strings from `project.yml`, the App Store Connect processing rules (`scripts/cmux-next/check-app-store-rules.py`), privacy manifest, VPN and private APIs, entitlements, extensions, on the source and on the exact IPA |
| Rejection history | `rejection-history.json` | every past rejection keeps a detector |
| App Store Connect | `asc validate --strict` on the AppStore configuration's version, `asc metadata validate` | review state Apple will refuse |
| Agent reviewer pass | `cmux-next-ios/scripts/app_review_agent_pass.py` | what confuses a reviewer who follows `reviewer-setup.md` |

The NEXT app sells nothing (no StoreKit), so there are no plan, subscription
or restore checks. A missing store listing (`metadata/`) or screenshots
(`screenshots/en-US/`) in this folder is a blocker, never a pass. What
XCUITest cannot judge (live provider sheets, a live Chief reply, a confirmed
deletion, a fold, iPad multitasking) is printed as a `GATE-NOTE` and listed as
a warning.

It runs on every feat-cmux-next push that touches the app and on pull requests
that change the gate. When App Review rejects us anyway, add the rejection and
its new detector to `rejection-history.json` in the fix's PR.

Run the lint locally (no build needed):

```bash
cmux-next-ios/scripts/app_review_gate.py lint --source-root . --lane appstore --check-urls
```
