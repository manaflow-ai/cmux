"use client";

import { isElectron } from "@/lib/electron";
import { WWW_ORIGIN } from "@/lib/wwwOrigin";
import { SignIn, useUser } from "@stackframe/react";
import { AnimatePresence, motion } from "framer-motion";
import { type CSSProperties } from "react";

export function SignInComponent() {
  const user = useUser({ or: "return-null" });
  const showSignIn = !user;
  return (
    <AnimatePresence mode="wait">
      {showSignIn ? (
        <motion.div
          key="signin"
          className="absolute inset-0 w-screen h-dvh flex items-center justify-center bg-white dark:bg-black z-[var(--z-global-blocking)]"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
        >
          {isElectron ? (
            <div
              className="absolute top-0 left-0 right-0 h-[24px]"
              style={{ WebkitAppRegion: "drag" } as CSSProperties}
            />
          ) : null}
          {isElectron ? (
            <div className="flex flex-col items-center gap-4 p-6 rounded-lg border border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900">
              <div className="text-center">
                <p className="text-neutral-900 dark:text-neutral-100 font-medium">
                  Sign in required
                </p>
                <p className="text-sm text-neutral-600 dark:text-neutral-400">
                  We'll open your browser to continue.
                </p>
              </div>
              <button
                onClick={() => {
                  const url = `${WWW_ORIGIN}/handler/sign-in?after_auth_return_to=/desktop/after-sign-in`;
                  // Open in external browser via Electron handler
                  window.open(url, "_blank", "noopener,noreferrer");
                }}
                className="px-4 py-2 rounded-md bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 hover:opacity-90"
              >
                Sign in with browser
              </button>
              <p className="text-xs text-neutral-500 dark:text-neutral-500 text-center">
                After signing in, you'll be returned automatically.
              </p>
              <SignIn />
            </div>
          ) : (
            <SignIn />
          )}
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}
