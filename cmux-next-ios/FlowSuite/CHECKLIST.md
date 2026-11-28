# iOS checks that still need a person

From Aziz's iOS notes and the App Store readiness pass in cmuxterm-hq. Everything else from those
notes runs from `flows.json`. Each item says why it is not a test yet.

| Check | Who | Why it is not automated |
| --- | --- | --- |
| Expired or revoked session at launch, on a real iPhone: the banner offers Sign in, sign-out takes at most 3 s | Aziz | Needs a real account whose session the server revoked; the simulator path is covered by `launch-session-restore` (AuthCoordinatorTeamScopeRecoveryTests) |
| Offline launch on a real iPhone: "Waiting for a connection…", then Couldn't load with Retry | Aziz | Needs the device's own radios off; the simulator shares the Mac's network, so a sim run would not prove it |
| App Store screenshots, iPhone and iPad, into `AppStoreReview/screenshots/en-US/` | Aziz, Leo approves | The capture suites run (AllUIStates*CaptureUITests), but choosing and approving the shots is a taste call and goes out to Apple |
| Signed-in run of the real App Review demo account, no Mac | Aziz or Leo | Uses the live demo account's credentials, which CI does not hold; the mock-Chief path runs in AppReviewGateUITests |
| Server revokes the Sign in with Apple token on Delete Account | Leo | Server-side and Apple-side; the app's ask-and-cancel is tested (AccountDeletionAppStoreUITests) |
| Tagged Mac + iPhone pairing is dogfood-ready: Mac `auth status` matches the launcher's account, phone reports `trusted-paired` and a usable RPC session | the person reloading the phone | Needs a physical iPhone and a signed build on the developer's Mac; signing never happens on the fleet |
| Toasts unified on CmuxMobileToast | Aziz | Open design work (a visible change with gallery variants), not a pass or fail check yet |
