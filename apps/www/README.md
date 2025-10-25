This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Analytics

The `apps/www` frontend now ships with optional [PostHog](https://posthog.com/) instrumentation. Provide the following environment variables to enable event capture:

- `POSTHOG_API_KEY` – server-side project API key used when emitting events from API routes.
- `POSTHOG_HOST` – optional override for the PostHog ingestion URL (defaults to `https://app.posthog.com`).
- `NEXT_PUBLIC_POSTHOG_KEY` – client-side key for loading `posthog-js` in the browser.
- `NEXT_PUBLIC_POSTHOG_HOST` – optional browser ingestion URL override (defaults to `https://app.posthog.com`).

Tracked events today:

- `sandbox_started` – fired after a Morph sandbox spin-up (includes team, environment linkage, hydration metadata, TTL, script flags, etc.).
- `environment_created` – triggered when a new environment snapshot is registered (ports, selected repos, maintenance/dev script flags).
- `model_usage` – records model provider usage for branch generation requests and fallback behaviour.

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

This project uses [`next/font`](https://nextjs.org/docs/app/building-your-application/optimizing/fonts) to automatically optimize and load [Geist](https://vercel.com/font), a new font family for Vercel.

## Learn More

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out [the Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome!

## Deploy on Vercel

The easiest way to deploy your Next.js app is to use the [Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme) from the creators of Next.js.

Check out our [Next.js deployment documentation](https://nextjs.org/docs/app/building-your-application/deploying) for more details.
