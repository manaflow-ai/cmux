"use client";

import { useState, useEffect } from "react";
import Link from "next/link";

function ThemeToggle() {
  const [theme, setTheme] = useState<"system" | "light" | "dark">("system");
  const [mounted, setMounted] = useState(false);

  // Load saved theme on mount
  useEffect(() => {
    setMounted(true);
    const stored = localStorage.getItem("theme") as "system" | "light" | "dark" | null;
    if (stored) setTheme(stored);
  }, []);

  // Apply theme changes
  useEffect(() => {
    if (!mounted) return;

    localStorage.setItem("theme", theme);
    const root = document.documentElement;

    const applyTheme = () => {
      if (theme === "system") {
        const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
        root.classList.toggle("dark", prefersDark);
      } else {
        root.classList.toggle("dark", theme === "dark");
      }
    };

    applyTheme();

    // Listen for system preference changes when in system mode
    if (theme === "system") {
      const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
      const handler = () => applyTheme();
      mediaQuery.addEventListener("change", handler);
      return () => mediaQuery.removeEventListener("change", handler);
    }
  }, [theme, mounted]);

  return (
    <div className="flex items-center bg-neutral-200 dark:bg-neutral-800 rounded-full p-1 gap-0.5">
      <button
        type="button"
        onClick={() => setTheme("system")}
        className={`p-2 rounded-full transition-colors ${
          theme === "system" ? "bg-white dark:bg-neutral-700 text-neutral-900 dark:text-white shadow-sm" : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-300"
        }`}
        aria-label="System theme"
      >
        <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <rect x="2" y="3" width="20" height="14" rx="2" strokeWidth="2" />
          <path d="M8 21h8" strokeWidth="2" strokeLinecap="round" />
          <path d="M12 17v4" strokeWidth="2" strokeLinecap="round" />
        </svg>
      </button>
      <button
        type="button"
        onClick={() => setTheme("light")}
        className={`p-2 rounded-full transition-colors ${
          theme === "light" ? "bg-white dark:bg-neutral-700 text-neutral-900 dark:text-white shadow-sm" : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-300"
        }`}
        aria-label="Light theme"
      >
        <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="4" strokeWidth="2" />
          <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" strokeWidth="2" strokeLinecap="round" />
        </svg>
      </button>
      <button
        type="button"
        onClick={() => setTheme("dark")}
        className={`p-2 rounded-full transition-colors ${
          theme === "dark" ? "bg-white dark:bg-neutral-700 text-neutral-900 dark:text-white shadow-sm" : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-300"
        }`}
        aria-label="Dark theme"
      >
        <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path d="M21 12.79A9 9 0 1111.21 3 7 7 0 0021 12.79z" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
    </div>
  );
}

export default function Footer() {
  return (
    <footer className="py-12 border-t border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-black/90">
      <div className="max-w-7xl mx-auto px-6">
        <div className="flex flex-col md:flex-row justify-between items-start gap-8">
          {/* Logo and description */}
          <div className="flex flex-col gap-3">
            <Link href="/" className="flex items-center text-neutral-900 dark:text-white">
              <svg
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                xmlns="http://www.w3.org/2000/svg"
              >
                <defs>
                  <linearGradient id="footerLogoGradient" x1="0%" y1="0%" x2="100%" y2="0%">
                    <stop offset="0%" stopColor="#00D4FF" />
                    <stop offset="100%" stopColor="#3B82F6" />
                  </linearGradient>
                </defs>
                <path
                  d="M6 4L18 12L6 20V15.5L12.5 12L6 8.5V4Z"
                  fill="url(#footerLogoGradient)"
                />
              </svg>
              <span className="text-xl font-medium">cmux</span>
            </Link>
            <p className="text-sm text-neutral-500 max-w-xs">
              Open-source AI coding agent orchestrator for running multiple agents in parallel.
            </p>
          </div>

          {/* Links columns */}
          <div className="flex flex-wrap gap-12">
            {/* Product */}
            <div className="flex flex-col gap-3">
              <span className="text-sm font-medium text-neutral-900 dark:text-white">Product</span>
              <Link href="/download" className="text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white transition-colors">
                Download
              </Link>
              <Link href="/docs" className="text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white transition-colors">
                Docs
              </Link>
              <Link href="/pricing" className="text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white transition-colors">
                Pricing
              </Link>
            </div>

            {/* Community */}
            <div className="flex flex-col gap-3">
              <span className="text-sm font-medium text-neutral-900 dark:text-white">Community</span>
              <Link href="https://github.com/manaflow-ai/cmux" className="text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white transition-colors">
                GitHub
              </Link>
              <Link href="https://discord.gg/cmux" className="text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white transition-colors">
                Discord
              </Link>
              <Link href="https://x.com/cmux_dev" className="text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white transition-colors">
                X (Twitter)
              </Link>
            </div>

            {/* Legal */}
            <div className="flex flex-col gap-3">
              <span className="text-sm font-medium text-neutral-900 dark:text-white">Legal</span>
              <Link href="/privacy-policy" className="text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white transition-colors">
                Privacy Policy
              </Link>
              <Link href="/terms-of-service" className="text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white transition-colors">
                Terms of Service
              </Link>
            </div>
          </div>
        </div>

        {/* Bottom row */}
        <div className="mt-6 pt-2 flex flex-col md:flex-row justify-between items-center gap-4">
          <p className="text-neutral-500 text-sm">
            © {new Date().getFullYear()} Manaflow, Inc. All rights reserved.
          </p>
          <div className="flex items-center gap-4">
            <ThemeToggle />
            <Link href="https://github.com/manaflow-ai/cmux" className="text-neutral-400 dark:text-neutral-500 hover:text-neutral-600 dark:hover:text-neutral-300 transition-colors">
              <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                <path fillRule="evenodd" clipRule="evenodd" d="M12 2C6.477 2 2 6.477 2 12c0 4.42 2.865 8.17 6.839 9.49.5.092.682-.217.682-.482 0-.237-.008-.866-.013-1.7-2.782.604-3.369-1.34-3.369-1.34-.454-1.156-1.11-1.464-1.11-1.464-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.831.092-.646.35-1.086.636-1.336-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0112 6.836c.85.004 1.705.114 2.504.336 1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.203 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.167 22 16.418 22 12c0-5.523-4.477-10-10-10z" />
              </svg>
            </Link>
            <Link href="https://discord.gg/cmux" className="text-neutral-400 dark:text-neutral-500 hover:text-neutral-600 dark:hover:text-neutral-300 transition-colors">
              <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                <path d="M20.317 4.37a19.791 19.791 0 0 0-4.885-1.515.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028 14.09 14.09 0 0 0 1.226-1.994.076.076 0 0 0-.041-.106 13.107 13.107 0 0 1-1.872-.892.077.077 0 0 1-.008-.128 10.2 10.2 0 0 0 .372-.292.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.01c.12.098.246.198.373.292a.077.077 0 0 1-.006.127 12.299 12.299 0 0 1-1.873.892.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.839 19.839 0 0 0 6.002-3.03.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.03zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.946 2.418-2.157 2.418z"/>
              </svg>
            </Link>
            <Link href="https://x.com/cmux_dev" className="text-neutral-400 dark:text-neutral-500 hover:text-neutral-600 dark:hover:text-neutral-300 transition-colors">
              <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/>
              </svg>
            </Link>
          </div>
        </div>
      </div>
    </footer>
  );
}
