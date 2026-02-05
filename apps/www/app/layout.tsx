import type { ReactNode } from "react";
import type { Metadata } from "next";
import { JetBrains_Mono } from "next/font/google";
import { Geist } from "next/font/google";
import localFont from "next/font/local";

import { stackServerApp } from "@/lib/utils/stack";
import { StackProvider, StackTheme } from "@stackframe/stack";

import clsx from "clsx";
import "./globals.css";

const articulat = localFont({
  src: "../public/fonts/articulat-cf-normal.ttf",
  variable: "--font-articulat",
});

export const metadata: Metadata = {
  title: "cmux - Manage AI coding agents in parallel — 10x your 10x engineers",
  description:
    "cmux spawns Claude Code, Codex, Gemini CLI, Amp, Opencode, and other coding agent CLIs in parallel across multiple tasks. For each run, cmux spawns an isolated VS Code instance via Docker with the git diff UI and terminal.",
  openGraph: {
    title:
      "cmux - Manage AI coding agents in parallel — 10x your 10x engineers",
    description:
      "Run multiple AI coding agents simultaneously with isolated VS Code instances",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title:
      "cmux - Manage AI coding agents in parallel — 10x your 10x engineers",
    description:
      "Run multiple AI coding agents simultaneously with isolated VS Code instances",
  },
};

const jetBrainsMono = JetBrains_Mono({
  subsets: ["latin"],
  weight: ["100", "200", "300", "400", "500", "600", "700", "800"],
  style: ["normal", "italic"],
  variable: "--font-jetbrains-mono",
});

const geist = Geist({
  subsets: ["latin"],
  weight: ["100", "200", "300", "400", "500", "600", "700", "800"],
  style: ["normal"],
  variable: "--font-geist-sans",
});

const themeScript = `
  (function() {
    const stored = localStorage.getItem('theme');
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const shouldBeDark = stored === 'dark' || (stored !== 'light' && prefersDark);
    document.documentElement.classList.toggle('dark', shouldBeDark);
  })();
`;

export default function RootLayout({
  children,
}: Readonly<{
  children: ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={clsx(
        jetBrainsMono.variable,
        geist.variable,
        articulat.variable,
      )}
      suppressHydrationWarning
    >
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className="antialiased bg-white dark:bg-black transition-colors">
        <StackTheme>
          <StackProvider app={stackServerApp}>{children}</StackProvider>
        </StackTheme>
      </body>
    </html>
  );
}
