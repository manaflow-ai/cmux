"use client";

import { MacDownloadLink } from "@/components/mac-download-link";
import type { MacDownloadUrls } from "@/lib/releases";
import clsx from "clsx";
import { CmuxIcon } from "@/components/icons/cmux-icon";
import { Download } from "lucide-react";
import Link from "next/link";
import type { ReactNode } from "react";
import { useEffect, useState } from "react";

export const NAV_ITEMS = [
  { id: "about", label: "About" },
  { id: "workflow", label: "Workflow" },
  { id: "verification", label: "Verification" },
];

type SiteHeaderProps = {
  linkPrefix?: string;
  showDownload?: boolean;
  fallbackUrl?: string;
  latestVersion?: string | null;
  macDownloadUrls?: MacDownloadUrls;
  extraEndContent?: ReactNode;
  githubUrl?: string;
  githubStars?: number | null;
};

const DEFAULT_DOWNLOAD_URLS: MacDownloadUrls = {
  universal: null,
  arm64: null,
  x64: null,
};

const DEFAULT_GITHUB_URL = "https://github.com/manaflow-ai/cmux";

const compactNumberFormatter = new Intl.NumberFormat("en-US", {
  notation: "compact",
  maximumFractionDigits: 1,
});

const standardNumberFormatter = new Intl.NumberFormat("en-US", {
  maximumFractionDigits: 0,
});

const formatStarCount = (stars?: number | null): string => {
  if (typeof stars !== "number" || !Number.isFinite(stars) || stars < 0) {
    return "—";
  }

  if (stars < 1000) {
    return standardNumberFormatter.format(stars);
  }

  return compactNumberFormatter.format(stars);
};

export function SiteHeader({
  linkPrefix = "",
  showDownload = true,
  fallbackUrl = "https://github.com/manaflow-ai/cmux/releases",
  latestVersion,
  macDownloadUrls,
  extraEndContent,
  githubUrl = DEFAULT_GITHUB_URL,
  githubStars = null,
}: SiteHeaderProps) {
  const effectiveUrls = macDownloadUrls ?? DEFAULT_DOWNLOAD_URLS;
  const [isScrolled, setIsScrolled] = useState(false);

  useEffect(() => {
    const handleScroll = () => {
      setIsScrolled(window.scrollY > 12);
    };

    handleScroll();
    window.addEventListener("scroll", handleScroll, { passive: true });

    return () => {
      window.removeEventListener("scroll", handleScroll);
    };
  }, []);

  return (
    <header
      className={clsx(
        "sticky top-0 z-40 backdrop-blur transition-colors",
        isScrolled
          ? "border-b border-white/10 bg-transparent"
          : "border-b border-transparent bg-transparent"
      )}
    >
      <div
        className={clsx(
          "mx-auto flex max-w-6xl items-center justify-between px-4 sm:px-6",
          isScrolled ? "py-3" : "py-4"
        )}
      >
        <Link aria-label="cmux" href="/">
          <div className="flex items-center gap-2">
            <CmuxIcon className="h-7 w-7" aria-hidden />
            <span className="text-xl font-bold tracking-wide text-white font-mono">
              cmux
            </span>
          </div>
        </Link>
        <nav className="hidden items-center gap-8 text-sm font-medium md:flex">
          {NAV_ITEMS.map((item) => (
            <Link
              key={item.id}
              className="text-neutral-300 transition hover:text-white"
              href={`${linkPrefix}#nav-${item.id}`}
            >
              {item.label}
            </Link>
          ))}
          {/* <Link className="text-neutral-300 transition hover:text-white" href="/tutorial">
            Tutorial
          </Link> */}
          <a
            className="text-neutral-300 transition hover:text-white"
            href={githubUrl}
            rel="noopener noreferrer"
            target="_blank"
          >
            GitHub
          </a>
          <a
            className="text-neutral-300 transition hover:text-white"
            href="https://cal.com/team/manaflow/meeting"
            rel="noopener noreferrer"
            target="_blank"
          >
            Contact
          </a>
        </nav>
        <div className="flex items-center gap-3">
          {extraEndContent}
          <GithubRepoButton stars={githubStars} url={githubUrl} />
          {showDownload ? (
            <MacDownloadLink
              autoDetect
              fallbackUrl={fallbackUrl}
              className="hidden md:inline-flex items-center gap-2 rounded-full bg-neutral-900 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-neutral-800"
              title={
                latestVersion
                  ? `Download cmux ${latestVersion} for macOS`
                  : "Download cmux for macOS"
              }
              urls={effectiveUrls}
            >
              <Download className="h-4 w-4" aria-hidden />
              <span>Download</span>
            </MacDownloadLink>
          ) : null}
          <a
            className="hidden md:inline-flex items-center gap-2 rounded-full bg-white px-4 py-2 text-sm font-semibold text-black shadow-sm transition hover:bg-neutral-100"
            href="https://cmux.sh"
            rel="noopener noreferrer"
            target="_blank"
          >
            <CmuxIcon className="h-4 w-4" aria-hidden />
            <span>Web</span>
          </a>
        </div>
      </div>
    </header>
  );
}

function GithubRepoButton({
  url,
  stars,
}: {
  url: string;
  stars?: number | null;
}) {
  const formattedStars = formatStarCount(stars);
  const ariaLabel =
    typeof stars === "number"
      ? `View cmux on GitHub (${formattedStars} stars)`
      : "View cmux on GitHub";

  return (
    <a
      href={url}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={ariaLabel}
      className="group relative hidden py-1 items-center gap-2 rounded-md border border-transparent pl-2 pr-2.5 text-sm font-medium text-neutral-300 transition-colors hover:border-white/20 hover:bg-white/5 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white md:flex"
    >
      <svg
        className="h-4.5 w-4.5 transition-colors group-hover:text-white"
        aria-hidden
        fill="currentColor"
        viewBox="0 0 24 24"
      >
        <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
      </svg>
      <span className="text-neutral-200 transition-colors group-hover:text-white leading-none">
        {formattedStars}
      </span>
    </a>
  );
}
