# Real App Store Sandbox purchase without an iPhone

The iOS Simulator cannot sign in a Sandbox Apple Account (iOS 26.3, 26.5 and
27.0 simulators, 2026-11-17): the password is accepted, then Apple's token call
`gsas.apple.com/grandslam/GsService2/postdata` answers 401 ("secureDeviceId not
available on simulator", "sending no BAA headers"). A Mac with Apple silicon
is real hardware, so the iOS app running natively on it ("Designed for iPad")
buys in the real Sandbox.

## Recipe

1. Register the Mac as a development device (its Provisioning UDID from
   `system_profiler SPHardwareDataType`) and make an `IOS_APP_DEVELOPMENT`
   profile for `com.cmux.app` that includes it.
2. Build Debug for `generic/platform=iOS` unsigned with
   `CMUX_MOBILE_APP_BUNDLE_ID=com.cmux.app` (fleet), then sign it where the
   signing identity lives: drop `PlugIns/`, embed the profile, sign the
   frameworks and the app with `application-identifier`, team id,
   `get-task-allow` and the keychain groups.
3. Wrap it: `cmux.app/Wrapper/CmuxMobileApp.app` plus the symlink
   `cmux.app/WrappedBundle -> Wrapper/CmuxMobileApp.app`.
4. On the Mac, register the wrapper so LaunchServices validates the profile:

   ```bash
   /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f -R -trusted ~/cmux.app
   ```

   Without this the record says `code-signing-info-not-authoritative`,
   StoreKit treats the app as Production, and the plans screen says plans
   aren't available (Production has no live products yet). After it, the
   record says `validation: profile validated` and `storekitagent` logs
   `[Client] com.cmux.app (cmux) Sandbox`.
5. Launch with the DEBUG overrides:

   ```bash
   open -g -n --env CMUX_MOBILE_STACK_EMAIL=... --env CMUX_MOBILE_STACK_PASSWORD=... \
     --env CMUX_MOBILE_BILLING_ORIGIN=http://127.0.0.1:<port> ~/cmux.app
   ```

   The billing origin must be a web stack that accepts development Stack
   sessions and grants Sandbox purchases (a per-tag dev web stack, or staging
   once it grants Sandbox).
6. Subscribe. macOS asks for the Sandbox account in its own sign-in window
   (choose Other Options, Don't Upgrade at the two-factor offer), then shows
   the In-App Purchase sheet ("For testing purposes only").

## Driving it with Cua Driver

- The Apple Pay style purchase sheet refuses to authorize while anything
  occludes it, and the Cua Driver agent cursor overlay counts. Run each click
  in a session with the cursor off (`start_session`, then
  `set_agent_cursor_enabled {"enabled": false}` with the same `session`).
- The iOS app's window exposes only its menus to accessibility, so click by
  screen coordinates (`scope: desktop`). The first click on an inactive window
  only activates it.
- Manage Subscription (`manageSubscriptionsSheet`) does nothing for an iOS
  app on a Mac, and the App Store's Sandbox Account setting offers only Sign
  Out, so turning off auto-renew is not available on this route. Sandbox
  subscriptions stop by themselves after a fixed number of renewals.
