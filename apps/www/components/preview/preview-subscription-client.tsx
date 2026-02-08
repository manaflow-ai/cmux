"use client";

import { useState } from "react";
import {
  ArrowLeft,
  Camera,
  Check,
  CheckCircle2,
  Clock,upo  Infinity as InfinityIcon,
  Loader2,
  Rocket,
  Server,
  Shield,
  Sparkles,
} from "lucide-react";
import Link from "next/link";
import clsx from "clsx";
import CmuxLogo from "@/components/logo/cmux-logo";

type TeamOption = {
  slugOrId: string;
  displayName: string;
};

type PreviewSubscriptionClientProps = {
  selectedTeamSlugOrId: string;
  teamOptions: TeamOption[];
  /** Map of teamSlugOrId -> isSubscribed (checked via Stack Auth team.getItem) */
  teamSubscriptionStatus: Record<string, boolean>;
  usedRuns: number;
  remainingRuns: number;
  freeLimit: number;
  userEmail?: string | null;
};

// Product ID configured in Stack Auth dashboard (for checkout)
const PREVIEW_PRO_PRODUCT_ID = "preview-pro";

const FEATURES = [
  {
    icon: InfinityIcon,
    title: "Unlimited previews",
    description: "No limits on screenshot previews for your PRs",
  },
  {
    icon: Rocket,
    title: "Priority processing",
    description: "Jump the queue with dedicated VM allocation",
  },
  {
    icon: Clock,
    title: "Extended sessions",
    description: "2-hour workspace sessions for complex projects",
  },
  {
    icon: Server,
    title: "All repositories",
    description: "Cover every repo in your team automatically",
  },
];

export function PreviewSubscriptionClient({
  selectedTeamSlugOrId,
  teamOptions,
  teamSubscriptionStatus,
  usedRuns,
  remainingRuns,
  freeLimit,
  userEmail,
}: PreviewSubscriptionClientProps) {
  const [selectedTeam, setSelectedTeam] = useState(selectedTeamSlugOrId);
  const [isCheckingOut, setIsCheckingOut] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isCurrentTeamSubscribed = teamSubscriptionStatus[selectedTeam] ?? false;
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
    <div className="w-full max-w-xl px-6 py-12 font-sans">
      {/* Back link */}
      <Link
        href="/preview"
        className="inline-flex items-center gap-1.5 text-sm text-neutral-400 hover:text-white transition-colors mb-8"
      >
        <ArrowLeft className="h-4 w-4" />
        Back to dashboard
      </Link>

      {/* Header */}
      <div className="mb-10">
        <div className="mb-6">
          <CmuxLogo height={28} wordmarkText="preview" />
        </div>
        <h1 className="text-[2rem] font-semibold tracking-tight text-white leading-tight mb-3">
          {isCurrentTeamSubscribed ? "You're on Pro" : "Upgrade to Pro"}
        </h1>
        <p className="text-base text-neutral-400 leading-relaxed">
          {isCurrentTeamSubscribed
            ? "Your team has unlimited screenshot previews for GitHub pull requests."
            : "Unlock unlimited screenshot previews for your GitHub pull requests."}
        </p>
      </div>

      {/* Usage indicator - compact inline version */}
      <div className="mb-8">
        <div className="flex items-center justify-between mb-2">
          <span className="text-sm text-neutral-400">Current usage</span>
          <span
            className={clsx(
              "text-sm font-medium",
              isCurrentTeamSubscribed
                ? "text-emerald-400"
                : quotaExceeded
                  ? "text-red-400"
                  : "text-white"
            )}
          >
            {isCurrentTeamSubscribed ? (
              <span className="flex items-center gap-1.5">
                <CheckCircle2 className="h-3.5 w-3.5" />
                Unlimited PRs
              </span>
            ) : (
              `${usedRuns} / ${freeLimit} free PRs`
            )}
          </span>
        </div>
        {!isCurrentTeamSubscribed && (
          <>
            <div className="h-1.5 w-full bg-white/5 rounded-full overflow-hidden">
              <div
                className={clsx(
                  "h-full rounded-full transition-all duration-500",
                  quotaExceeded
                    ? "bg-gradient-to-r from-red-500 to-red-400"
                    : "bg-gradient-to-r from-blue-500 to-blue-400"
                )}
                style={{ width: `${usagePercent}%` }}
              />
            </div>
            {quotaExceeded && (
              <p className="text-sm text-red-400/90 mt-2">
                Free tier limit reached. Subscribe to continue.
              </p>
            )}
          </>
        )}
      </div>

      {/* Main pricing section */}
      <div className="relative rounded-2xl border border-white/[0.08] bg-white/[0.02] overflow-hidden mb-8">
        {/* Subtle gradient accent */}
        <div className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-blue-500/50 to-transparent" />

        <div className="p-6">
          {/* Plan header */}
          <div className="flex items-start justify-between mb-6">
            <div>
              <div className="flex items-center gap-2 mb-1">
                <Sparkles className="h-4 w-4 text-blue-400" />
                <span className="text-xs font-medium uppercase tracking-wider text-blue-400">
                  Pro Plan
                </span>
              </div>
              <h2 className="text-xl font-semibold text-white">Preview Pro</h2>
            </div>
            <div className="text-right">
              <div className="flex items-baseline gap-0.5">
                <span className="text-3xl font-bold text-white">$30</span>
                <span className="text-sm text-neutral-500">/mo</span>
              </div>
            </div>
          </div>

          {/* Team selector */}
          {teamOptions.length > 1 && (
            <div className="mb-6">
              <label className="text-xs font-medium text-neutral-500 uppercase tracking-wider mb-2 block">
                Team
              </label>
              <div className="relative">
                <select
                  value={selectedTeam}
                  onChange={(e) => setSelectedTeam(e.target.value)}
                  className="w-full appearance-none rounded-lg border border-white/10 bg-white/5 px-4 py-2.5 text-sm text-white focus:border-white/20 focus:outline-none focus:ring-1 focus:ring-white/10 pr-10 cursor-pointer transition-colors hover:bg-white/[0.07]"
                >
                  {teamOptions.map((team) => {
                    const isSubscribed = teamSubscriptionStatus[team.slugOrId] ?? false;
                    return (
                      <option key={team.slugOrId} value={team.slugOrId}>
                        {team.displayName}{isSubscribed ? " ✓" : ""}
                      </option>
                    );
                  })}
                </select>
                <div className="pointer-events-none absolute inset-y-0 right-0 flex items-center pr-3">
                  <svg
                    className="h-4 w-4 text-neutral-500"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      strokeWidth={2}
                      d="M19 9l-7 7-7-7"
                    />
                  </svg>
                </div>
              </div>
            </div>
          )}

          {/* Features list */}
          <ul className="space-y-3 mb-6">
            {FEATURES.map((feature) => (
              <li key={feature.title} className="flex items-start gap-3">
                <div className="flex-shrink-0 mt-0.5">
                  <div className="h-5 w-5 rounded-full bg-blue-500/10 flex items-center justify-center">
                    <Check className="h-3 w-3 text-blue-400" />
                  </div>
                </div>
                <div>
                  <span className="text-sm text-white font-medium">
                    {feature.title}
                  </span>
                  <span className="text-sm text-neutral-500 ml-1.5">
                    — {feature.description}
                  </span>
                </div>
              </li>
            ))}
          </ul>

          {/* CTA button */}
          {isCurrentTeamSubscribed ? (
            <div className="w-full h-11 rounded-lg font-medium text-sm bg-emerald-500/10 border border-emerald-500/20 text-emerald-400 flex items-center justify-center gap-2">
              <CheckCircle2 className="h-4 w-4" />
              Subscribed
            </div>
          ) : (
            <button
              onClick={handleCheckout}
              disabled={isCheckingOut}
              className={clsx(
                "w-full h-11 rounded-lg font-medium text-sm transition-all duration-200",
                "bg-white text-neutral-900 hover:bg-neutral-100",
                "disabled:opacity-60 disabled:cursor-not-allowed",
                "flex items-center justify-center gap-2"
              )}
            >
              {isCheckingOut ? (
                <>
                  <Loader2 className="h-4 w-4 animate-spin" />
                  Redirecting to checkout...
                </>
              ) : (
                "Subscribe to Pro"
              )}
            </button>
          )}

          {error && (
            <p className="text-sm text-red-400 mt-3 text-center">{error}</p>
          )}
        </div>

        {/* Footer */}
        <div className="px-6 py-4 border-t border-white/[0.06] bg-white/[0.01]">
          <div className="flex items-center justify-center gap-4 text-xs text-neutral-500">
            <span className="flex items-center gap-1.5">
              <Shield className="h-3.5 w-3.5" />
              Secure checkout
            </span>
            <span className="h-3 w-px bg-white/10" />
            <span>Cancel anytime</span>
          </div>
        </div>
      </div>

      {/* Feature highlights - horizontal cards */}
      <div className="grid grid-cols-2 gap-3">
        <div className="rounded-xl border border-white/[0.06] bg-white/[0.015] p-4 hover:bg-white/[0.025] transition-colors">
          <Camera className="h-5 w-5 text-blue-400 mb-3" />
          <h3 className="text-sm font-medium text-white mb-1">
            Auto Screenshots
          </h3>
          <p className="text-xs text-neutral-500 leading-relaxed">
            Captured on every PR update automatically
          </p>
        </div>
        <div className="rounded-xl border border-white/[0.06] bg-white/[0.015] p-4 hover:bg-white/[0.025] transition-colors">
          <Rocket className="h-5 w-5 text-emerald-400 mb-3" />
          <h3 className="text-sm font-medium text-white mb-1">
            Fast Processing
          </h3>
          <p className="text-xs text-neutral-500 leading-relaxed">
            Priority queue for instant previews
          </p>
        </div>
      </div>

      {/* Email footer */}
      {userEmail && (
        <p className="text-center text-xs text-neutral-600 mt-8">
          Signed in as {userEmail}
        </p>
      )}
    </div>
  );
}
