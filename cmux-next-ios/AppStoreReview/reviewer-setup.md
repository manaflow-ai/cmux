# Reviewer setup for cmux-next-ios

App Review gets a demo account and no Mac. The account has a Cloud Chief, which
runs in cmux Cloud and answers in chat, so the reviewer signs in, opens the Chief
on Home and sends a message.

## Where each live value lives

Nothing below is in git. `asc_review_package.py sync-notes` reads them when it
writes the notes and stops if any is empty.

| Value | Where it lives |
|---|---|
| Demo account email | App Store Connect, App Review Information, demo account field. A `@mailinator.com` address gets its public inbox link in the notes by itself. |
| Public inbox URL | Derived from a Mailinator demo account, or kept from a Mailinator link already in the App Store Connect notes |
| Contact email and phone | App Store Connect, App Review Information |
| Name of the demo account's Cloud Chief | Repository variable `IOS_APPSTORE_REVIEW_CHIEF_NAME`, passed as `CMUX_IOS_REVIEW_CHIEF_NAME` |

Sign-in uses a one-time email code ("Continue with email"), so there is no
password field to fill.

## The review path

`review-notes-asc.txt` walks the reviewer through:

1. Sign-in: "Continue with email", the code from the public inbox, "Check your
   email".
2. First launch: "Choose a space" (Personal), "Connect your Mac" (Not now) and
   the notifications step, whichever the account gets.
3. The review demo path: open the Cloud Chief on Home, message it, read the
   reply. The notes mark this block with `## REVIEW DEMO STEPS: START` and
   `## REVIEW DEMO STEPS: END`. The review demo path work replaces the numbered
   steps between the markers with its exact steps; the `##` lines never reach the
   reviewer.
4. Account deletion: Settings, the account row, "Account", "Delete Account".

Every quoted label must be a string the release app shows; the test reads the
app source to check.

## Before a submission

- The demo account exists in production, has one space, and its Cloud Chief has
  its brain on in the production Cloud service. If the brain is off, Home says
  "Cloud Chief is turned off." or "Cloud Chief is not available on this server."
  and the reviewer has nothing to message.
- `IOS_APPSTORE_REVIEW_CHIEF_NAME` matches the Chief's name on Home.
- The demo account email and contact are filled in App Store Connect.
- A reviewer may delete the demo account (the notes ask them to try it last).
  After a review that did, make the account and its Cloud Chief again before the
  next submission.
