"use client";

import { useState } from "react";
import { Camera, Check, CreditCard, Loader2, Zap } from "lucide-react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import CmuxLogo from "@/components/logo/cmux-logo";

type TeamOption = {
  slugOrId: string;
  displayName: string;
};

type PreviewSubscriptionClientProps = {
  selectedTeamSlugOrId: string;
  teamOptions: TeamOption[];
  usedRuns: number;
  remainingRuns: number;
  freeLimit: number;
  userEmail?: string | null;
};

// Product ID configured in Stack Auth dashboard
const PREVIEW_PRO_PRODUCT_ID =
  process.env.NEXT_PUBLIC_PREVIEW_PAYWALL_PRODUCT_ID ?? "preview-pro";

export function PreviewSubscriptionClient({
  selectedTeamSlugOrId,
  teamOptions,
  usedRuns,
  remainingRuns,
  freeLimit,
  userEmail,
}: PreviewSubscriptionClientProps) {
  const [selectedTeam, setSelectedTeam] = useState(selectedTeamSlugOrId);
  const [isCheckingOut, setIsCheckingOut] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const quotaExceeded = remainingRuns <= 0;
  const usagePercent = Math.min(100, (usedRuns / freeLimit) * 100);

  const handleCheckout = async () => {
    setIsCheckingOut(true);
    setError(null);

    try {
      const response = await fetch("/api/preview/checkout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          productId: PREVIEW_PRO_PRODUCT_ID,
          teamSlugOrId: selectedTeam,
        }),
      });

      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || "Failed to create checkout session");
      }

      const { checkoutUrl } = await response.json();
      window.location.href = checkoutUrl;
    } catch (err) {
      const message = err instanceof Error ? err.message : "Checkout failed";
      console.error("[PreviewSubscriptionClient] Checkout error:", err);
      setError(message);
      setIsCheckingOut(false);
    }
  };

  return (
    <div className="w-full max-w-2xl px-6 py-10 font-sans">
      {/* Header */}
      <div className="pb-6">
        <Link href="/preview" className="inline-block pb-6">
          <CmuxLogo height={32} wordmarkText="preview" />
        </Link>
        <h1 className="text-3xl font-semibold tracking-tight text-white pb-2">
          Upgrade to Preview Pro
        </h1>
        <p className="text-lg text-neutral-300/85">
          Unlock unlimited screenshot previews for your GitHub PRs
        </p>
      </div>

      {/* Usage Status Card */}
      <div className="rounded-xl border border-white/10 bg-white/[0.02] backdrop-blur-sm p-6 mb-6">
        <div className="flex items-center justify-between pb-4">
          <h2 className="text-sm font-medium text-neutral-400">Current Usage</h2>
          {userEmail && (
            <span className="text-xs text-neutral-500">{userEmail}</span>
          )}
        </div>

        {/* Progress bar */}
        <div className="w-full bg-neutral-800 rounded-full h-2 mb-3">
          <div
            className={`h-2 rounded-full transition-all ${
              quotaExceeded ? "bg-red-500" : "bg-blue-500"
            }`}
            style={{ width: `${usagePercent}%` }}
          />
        </div>

        <div className="flex items-center justify-between text-sm">
          <span className={quotaExceeded ? "text-red-400" : "text-white"}>
            {usedRuns} / {freeLimit} free PRs used
          </span>
          {quotaExceeded && (
            <span className="text-red-400 text-xs">Quota exceeded</span>
          )}
        </div>

        {quotaExceeded && (
          <div className="mt-4 p-3 rounded-lg bg-red-500/10 border border-red-500/20">
            <p className="text-sm text-red-300">
              You&apos;ve reached your free tier limit. Subscribe to continue receiving
              screenshot previews on your PRs.
            </p>
          </div>
        )}
      </div>

      {/* Team selector */}
      {teamOptions.length > 1 && (
        <div className="pb-6">
          <label className="text-sm text-neutral-400 pb-2 block">
            Subscribe for team
          </label>
          <select
            value={selectedTeam}
            onChange={(e) => setSelectedTeam(e.target.value)}
            className="w-full appearance-none rounded-lg border border-white/10 bg-white/5 px-4 py-3 text-sm text-white focus:border-white/20 focus:outline-none"
          >
            {teamOptions.map((team) => (
              <option key={team.slugOrId} value={team.slugOrId}>
                {team.displayName}
              </option>
            ))}
          </select>
        </div>
      )}

      {/* Pricing Card */}
      <div className="rounded-xl border border-blue-500/30 bg-gradient-to-b from-blue-500/5 to-transparent p-6 mb-6">
        <div className="flex items-start justify-between pb-4">
          <div>
            <h3 className="text-xl font-semibold text-white pb-1">Preview Pro</h3>
            <p className="text-neutral-400 text-sm">Unlimited screenshot previews</p>
          </div>
          <div className="text-right">
            <span className="text-3xl font-bold text-white">$29</span>
            <span className="text-neutral-400 text-sm">/month</span>
          </div>
        </div>

        <ul className="space-y-3 pb-6">
          <li className="flex items-center gap-3 text-sm text-neutral-300">
            <Check className="h-4 w-4 text-blue-400 shrink-0" />
            Unlimited screenshot previews
          </li>
          <li className="flex items-center gap-3 text-sm text-neutral-300">
            <Check className="h-4 w-4 text-blue-400 shrink-0" />
            Priority VM allocation
          </li>
          <li className="flex items-center gap-3 text-sm text-neutral-300">
            <Check className="h-4 w-4 text-blue-400 shrink-0" />
            Extended workspace session (2 hours)
          </li>
          <li className="flex items-center gap-3 text-sm text-neutral-300">
            <Check className="h-4 w-4 text-blue-400 shrink-0" />
            All repositories in your team
          </li>
        </ul>

        <Button
          onClick={handleCheckout}
          disabled={isCheckingOut}
          className="w-full h-12 bg-blue-500 hover:bg-blue-600 text-white text-base font-medium"
        >
          {isCheckingOut ? (
            <Loader2 className="h-5 w-5 animate-spin mr-2" />
          ) : (
            <CreditCard className="h-5 w-5 mr-2" />
          )}
          {isCheckingOut ? "Redirecting to checkout..." : "Subscribe Now"}
        </Button>

        {error && (
          <p className="text-sm text-red-400 pt-3 text-center">{error}</p>
        )}

        <p className="text-xs text-neutral-500 text-center pt-4">
          Secure payment via Stripe. Cancel anytime.
        </p>
      </div>

      {/* Features grid */}
      <div className="grid grid-cols-2 gap-4 pb-6">
        <div className="rounded-lg border border-white/5 bg-white/[0.02] p-4">
          <Camera className="h-5 w-5 text-blue-400 mb-2" />
          <h4 className="text-sm font-medium text-white pb-1">
            Auto Screenshots
          </h4>
          <p className="text-xs text-neutral-400">
            Screenshots captured automatically on every PR update
          </p>
        </div>
        <div className="rounded-lg border border-white/5 bg-white/[0.02] p-4">
          <Zap className="h-5 w-5 text-yellow-400 mb-2" />
          <h4 className="text-sm font-medium text-white pb-1">
            Fast Processing
          </h4>
          <p className="text-xs text-neutral-400">
            Pro subscribers get priority queue for faster previews
          </p>
        </div>
      </div>

      {/* Back link */}
      <div className="text-center">
        <Link
          href="/preview"
          className="text-sm text-neutral-400 hover:text-white transition-colors"
        >
          Back to Preview Dashboard
        </Link>
      </div>
    </div>
  );
}
