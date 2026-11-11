# Review account: a working Chief with no Mac

The cmux iOS app (`cmux-next-ios/`, which replaces the classic `ios/` app under the production App
Store record) signs in and opens Home. The account's Hosted Chief has no `brain_place`: the Cloud
Chief brain in the production API Worker (`cloud-api.cmux.dev`) answers it, so a reviewer needs no
Mac, no pairing, no tailnet and no Cloud machine. This page is the operator setup that makes that
Chief answer for the review account, and the steps the reviewer follows.

Credentials, account emails, inbox links and keys go only in the store's review information form,
never here.

## Why a Hosted Chief, not a demo mode or a review Mac

- **Every production signup already gets a Hosted Chief.** The signup outbox runs
  `chief.default.ensure` (`backend/apps/api/src/domains/user-chief-default.ts`), which makes the
  Chief and its main conversation. Home opens that conversation (`ChiefSources`, `chief.list`).
- **Production runs Cloud Chief brains, but no machines.** `wrangler.jsonc` production sets
  `CHIEF_BRAIN_ENABLED=1` and model `claude-opus-5-5`, and leaves `HANDS_ENABLED` unset.
  - So signup cannot bind a default machine, and leaves the brain unconfigured (`activateDefault`
    answers `provisioning_pending`, `src/chief-brain/brain-do.ts`).
  - A brain its owner turns on (`PUT /v1/chiefs/<agent>/brain {"enabled": true, ...}`) then answers
    with no machine at all.
- **Who may run turns on a metered model is server config, not app code.**
  - `meteredOwner` (`src/model-gateway/routes.ts`) reads `CHIEF_BRAIN_CLAUDE_OWNERS` plus the
    secret `CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA`, which exists for owners that change often, such as
    a demo's test user (`src/chief-brain/claude-auth.ts`).
  - Turning the brain on for an owner not on that list is refused with `chief_claude_unavailable`.
  - Each turn also needs the payer team's prepaid credits (`src/chief-brain/brain-gateway.ts`),
    granted through the operator route `POST /v1/internal/credits` (`src/credits-admin.ts`).
- **So the review account is marked on the server only.** Its personal team is on the owner list and
  has a credits grant. The app has no review switch, no hardcoded account and no canned
  content: the reviewer uses the same Home, Chief and chat every person gets.

## What the app does for this path

- **Setup never requires a Mac.** After sign-in, "Connect your Mac" offers **Not now**, and
  notifications offer **Not now**. The team step shows only for an account with more than one team.
- **Home reads the Cloud Chief's brain.** It reads on sign-in, on every Home visit, back from the
  background and on a network change.
- **While the brain is off, Home shows a "Chief Is Off" card** (`ChiefOffCardView`) at the top:
  - "It doesn't answer messages until you turn it on." with **Turn On**.
  - The button shows its spinner while the request is out. A failure says "It couldn't be turned
    on. Check your connection and try again." with **Try Again**.
  - When the service refuses because the account may not run the Chief's model
    (`chief_claude_unavailable`, `chief_model_unavailable`), the card says "Chief isn't available
    on this account." with no button. The next return to the app offers Turn On again, so a fix
    on the server takes effect without a reinstall.
- **Only the person's tap turns a brain on.** A read never does.
- **When it is on,** the card goes and Home lists Chief ("Main · Cloud"); its conversation answers.

## Operator setup, once per review account (production)

Each step names the tool that already does it. Only a person starts steps 1 and 3; nothing runs them
on a schedule.

1. **Make the account.** Dispatch `.github/workflows/cloud-capture-provision.yml` on `feat-cmux-next`
   with `target: app-review` (`scripts/ci/cloud_capture_provision.py`, target `app-review`). It runs in
   environment `cloud-vm-production`, which asks for its approval.
   - It finds or makes the review account in the production sign-in project, verified, with a fresh
     random password and the `pro` plan. It checks that the password signs in, then seals the email and
     password to this repository's `release` environment as `APP_REVIEW_STACK_EMAIL` and
     `APP_REVIEW_STACK_PASSWORD`. The run's artifact holds only ciphertext; store it with
     `python3 scripts/ci/sealed_secrets.py put sealed-secrets.json` (`docs/ci-sealed-secrets.md`).
   - The log names the account's sign-in user id (not a secret), which steps 3 and 4 use. Every run
     rotates the password, so rerunning is how it is replaced.
   - The shipped app signs in only by emailed code or OAuth, not by password. So the reviewer needs an
     account whose code email they can open from the review notes (a public disposable inbox). That
     account is made by hand in the production sign-in project, verified, with a fictional display
     name; this target's password account serves the check in step 5 and any password path.
2. **Sign in once.** Do this with the account in the cmux iOS app, so signup makes the Hosted Chief.
   Tap Not now on Connect your Mac. Do not create other Chiefs or conversations.
3. **Grant credits.** Use the operator credits route on `cloud-api.cmux.dev`,
   `POST /v1/internal/credits` (`backend/apps/api/src/credits-admin.ts`), with the billing operator
   key (`BILLING_LEVELS_KEY`). No workflow holds that key, so a person who has it sends this:
   - action `grant`, and `stack_user` set to the account's sign-in user id;
   - a small amount that covers a few days of review turns, a unique `key`, your `actor`;
   - a `reason` such as "app review account".
   The answer names the personal team id (`team_...`).
4. **Add the team to the owner list.** Open a PR that adds that `team_...` id to
   `CHIEF_BRAIN_CLAUDE_OWNERS` in `env.production.vars` of `backend/apps/api/wrangler.jsonc`. A team
   id is not a secret. It reaches production with the next normal promote (`backend.yml`,
   `scripts/cmux-next/release/prod-promote.ts`); no secret is set by hand and no person holds a value.
   - The secret `CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA` takes the same ids without a deploy, but setting it
     replaces its whole value and no workflow sets it. Use it only when the promote cannot wait.
5. **Check it.** In the app, on the review account, Home shows "Chief Is Off". Tap Turn On, open Chief,
   send "hello" and wait for the reply. The card does not come back after a relaunch.
   - If the card says "Chief isn't available on this account.", step 4 has not reached production.
     Check that the promote carried it, then leave the app and come back to get Turn On again.
   - Without a phone: a simulator build of a shipping configuration signs in by password from
     `CMUX_MOBILE_STACK_EMAIL` and `CMUX_MOBILE_STACK_PASSWORD` (`CmuxMobileAuthModel`), which a job in
     the `release` environment reads from step 1's secrets. `backend/scripts/chief-durable-evals.ts`
     shows the same check over HTTP: `PUT /v1/chiefs/<agent>/brain {"enabled": true, ...}`, then one
     turn.
6. **Fill the review form.** Leave the account signed in nowhere else. In the review information
   form, enter the email, "no password: sign in with the emailed code", the public inbox link and
   the reviewer steps below.

## Reviewer steps (paste into the review notes)

1. Open cmux and tap "Continue with email".
2. Enter the demo account email from these notes and tap "Continue".
3. Open the inbox link from these notes, open the newest cmux email and type its code into "Check
   your email". The app signs in by itself once the code is complete.
4. On "Connect your Mac", tap "Not now". No Mac, pairing or other device is needed. If the app asks
   about notifications, tap "Not now" there too.
5. Home opens. Tap Chief (it is labeled "Main · Cloud"), type a message (for example "What can you
   help me with?") and send it. Chief answers in the conversation within a few seconds.
6. If Home shows "Chief Is Off" instead, tap "Turn On", then open Chief and send the message.

## Checks before each submission

- The steps above work from a phone that has never signed in to the account, on a network outside
  the office.
- The account's credits read above zero (operator credits route, action `read`).
- The owner list still names the account's team: `CHIEF_BRAIN_CLAUDE_OWNERS` in `wrangler.jsonc`
  on the serving commit, or the secret if it was used (a replaced secret drops it).

## After review

Remove the team id from the owner list (a PR to `wrangler.jsonc`, or the secret if it was used). Archive the account's conversations. Then
change the account's inbox or delete the account, because anyone with the public inbox can sign in.
