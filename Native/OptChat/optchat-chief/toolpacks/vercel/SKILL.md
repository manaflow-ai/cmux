---
name: vercel
description: Use the vercel CLI with this Chief's own Vercel token (deploys, previews, env vars, logs), and sign the Chief in to Vercel with a pasted token. Use when a task touches a Vercel project or a vercel command fails for auth.
cmux-managed: true
---

# Vercel (tool pack `vercel`)

A data-only tool pack (plans/cmux-next/chief-toolpacks-DESIGN.md section 3): `vercel` on your PATH
gets this Chief's own token as `VERCEL_TOKEN` on every call. You never write the token anywhere.

1. `chief pack status vercel`: who, or not signed in. `chief pack check vercel` runs `vercel whoami`.
2. Not signed in: ask the person for a token made at https://vercel.com/account/tokens (scope:
   the team the task needs, an expiry). They paste it into a file only they and you can read, or you
   run `chief pack paste vercel -` and they paste it into that terminal; never in chat.
3. Missing CLI: `chief pack install vercel` (brew or npm).
4. Sign out: `chief pack logout vercel`, then delete the token on the Vercel page.
5. Deploys to production follow the person's rules: staging first, then production.
