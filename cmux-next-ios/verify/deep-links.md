# cmux links on the phone

A cmux link opens what it names in the app. That covers links the Mac copies (Copy Link), links Chief and agents write, and the https forms that cmux.com and the Cloud service hand out. It works for links tapped inside the app (agent chats, Chief, the Feed) and for links opened outside it (Safari, Messages, Notes, a QR code).

## What opens

The grammar is the Mac's (`Packages/macOS/CmuxNext/Sources/CmuxNextActions/DeepLink`). The parser is `CmuxMobileModel/CmuxLink.swift`, and the router is `CmuxMobileShell/ShellModel+Links.swift`.

| Link | Opens |
| --- | --- |
| `cmux://workspace/ws_…` | that workspace |
| `cmux://tab/tab_…` | that workspace at that tab |
| `cmux://pane/pane_…` | the pane's selected tab |
| `cmux://session/<id>[#turn-…]`, `cmux://chief/<home>/session/<id>` | the agent chat bound to the session |
| `cmux://agent/<harness>/<session>[?message=…]`, `https://cmux.com/deeplink/agent?harness=&session=` | the chat that adopted the session; otherwise the terminal whose agent reports that harness session id |
| `cmux://group/grp_…[/workspace/ws_…]`, `https://cloud-api.cmux.dev/g/grp_…` | the group's workspace, or the Workspaces list |
| `cmux://conversation/<id>[/message/<id>]` | Chief, on Home |
| `https://cmux.com/link/<kind>/<id>` | the same as `cmux://<kind>/<id>` |

- **Schemes.** The app registers `cmux`, `cmux-nightly`, `cmux-rc` and `cmux-dev`. A tagged Mac's `cmux-dev-<tag>` links open when tapped inside the app, but iOS cannot register a wildcard scheme, so those links do not open from outside it.
- **How a link is matched.** Links match on the Mac's public ids. The tree (`list-workspaces`) carries `resource_id`, `tab_resource_id` and the pane's `resource_id`, and `list-agents` carries `agent_session_id`.
- **When nothing matches yet.** A link the phone cannot place waits, like a tapped notification does (`NotificationRouter`, 10 s budget), while a Mac of the active team is answering (its tree is loading or reconnecting).
- **Agent links.** As on the Mac (`DeepLink.agentTabs`), an agent link opens the chat bound to the session first. Otherwise it opens a terminal whose agent reports that session under the link's harness, then one whose agent names no known harness. It never opens a terminal running another harness.
- **Nightly's legacy links.** `workspace/<uuid>` links are not opened: the phone has no stable id to match them by.
- **Launch restore.** A link decides where the app opens, so the launch restore of the last workspace is dropped. After that it shows "Couldn't find that link on your Macs." and stays on the current screen.
- **Safety.** A link is an address: it never creates, starts or runs anything. Every query parameter except `message` is ignored. The `cmux://auth-callback` sign-in callback and the `cmux-next://pair` pairing code are not links.

## Universal links: the server change still needed

The app claims these domains in simulator builds (`App/CmuxMobileApp-Simulator.entitlements`) and, once their profile carries the Associated Domains capability, in the App Store distribution builds (TestFlight, TestFlightStaging, AppStore: `App/CmuxMobileApp-TestFlight-Links*.entitlements`, picked by `CMUX_MOBILE_ASSOCIATED_DOMAINS=YES`):

- `applinks:cmux.com`
- `applinks:www.cmux.com`
- `applinks:cloud-api.cmux.dev`
- `applinks:cloud-api-staging.cmux.dev`

As of 2026-10-27, none of these hosts serves an AASA file: `/.well-known/apple-app-site-association` returns 404 on all four. Until they do, iOS treats https links as web pages. The cmux.com page's **Open in cmux** button still opens the app, through `cmux://`.

Each host must serve this at `/.well-known/apple-app-site-association`, with `Content-Type: application/json`, no redirect, over https:

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["7WLXT3NR37.dev.cmux.app.internal"],
        "components": [
          { "/": "/link/*" },
          { "/": "/*/link/*" },
          { "/": "/deeplink/agent" },
          { "/": "/*/deeplink/agent" },
          { "/": "/g/*" }
        ]
      }
    ]
  }
}
```

Where each host serves it:

- **cmux.com**: a route handler at `web/app/.well-known/apple-app-site-association/route.ts`. Add `.well-known` to the `web/proxy.ts` matcher's exclusions so the locale proxy does not redirect it. Also add a `/link/[kind]/[id]` fallback page that hands off to `cmux://<kind>/<id>`, as `/deeplink/agent` does. The site deploys from `main` only.
- **cloud-api(-staging).cmux.dev**: a `GET /.well-known/apple-app-site-association` route in `backend/apps/api/src/index.ts`, next to the `/g/` page.

cmux-next ships under the App Store app, so `appIDs` also lists `7WLXT3NR37.com.cmux.app`. Then, for device builds:

1. Turn on the Associated Domains capability for `dev.cmux.app.internal` and `com.cmux.app`. As of 2026-10-27 `dev.cmux.app.internal` has `IN_APP_PURCHASE`, `PUSH_NOTIFICATIONS`, `USERNOTIFICATIONS_TIMESENSITIVE` and `APPLE_ID_AUTH`. Turning on a capability invalidates the App ID's existing profiles.
2. Regenerate their App Store profiles ("cmux Internal Distribution", its CI copy in the release environment's `IOS_BETA_PROVISIONING_PROFILE_INTERNAL_BASE64`, and "cmux App Store CI").
3. Nothing else: `scripts/testflight-build.sh` reads the profile and, when it carries Associated Domains, builds with `CMUX_MOBILE_ASSOCIATED_DOMAINS=YES` and signs the domains in (the `--from-archive` signing too). Until then it signs without them and warns, so a profile without Associated Domains never breaks a build. (Time Sensitive notifications, by contrast, are required: the script refuses a profile without them.) The INTERNAL nightly signs with the script on `rc/cnx-ios-builder`, so this takes effect there after that branch is fast-forwarded.

## Legal and support links

Settings → About and the Welcome footer link to the live cmux.com pages. `https://cmux.com/terms` and `/privacy` were 404s. They are now:

- `https://cmux.com/terms-of-service`
- `https://cmux.com/privacy-policy`
- `https://cmux.com/docs`
- the GitHub issues page

App Store Connect already lists `/privacy-policy` (`testflight-metadata.md`).

## Proof

The fleet's `cmux-next-ios-sim.sh` admits only its fixed modes, so the UI tests run on an AWS Mac's simulator, over SSH:

```sh
xcodebuild test -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Debug \
  -destination id=<sim> -only-testing:CmuxMobileAppUITests/DeepLinkUITests
```

Run it with `simctl io <sim> recordVideo` going. The parser and router tests are `CmuxLinkTests`, which also checks every vector in `schemas/deeplinks/agent-link.json`, and `LinkRouteTests`. They run in the kit suite: `cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg test`.
