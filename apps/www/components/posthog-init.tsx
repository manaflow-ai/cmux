"use client";

import { useEffect } from "react";
import posthog from "posthog-js";

const POSTHOG_KEY = process.env.NEXT_PUBLIC_POSTHOG_KEY;
const POSTHOG_HOST =
  process.env.NEXT_PUBLIC_POSTHOG_HOST ?? "https://app.posthog.com";

let hasInitialized = false;

export function PostHogInit(): null {
  useEffect(() => {
    if (!POSTHOG_KEY || hasInitialized) {
      return;
    }
    posthog.init(POSTHOG_KEY, {
      api_host: POSTHOG_HOST,
      capture_pageview: true,
      capture_pageleave: true,
    });
    hasInitialized = true;
  }, []);

  return null;
}
