"use client";

import { env } from "@/client-env";
import { getRandomKitty } from "@/components/kitties";
import CmuxLogoMark from "@/components/logo/cmux-logo-mark";
import { isElectron } from "@/lib/electron";
import { SignIn, useUser } from "@stackframe/react";
import { useSuspenseQuery } from "@tanstack/react-query";
import { Authenticated, ConvexProviderWithAuth } from "convex/react";
import { AnimatePresence, motion } from "framer-motion";
import {
  Suspense,
  useCallback,
  useEffect,
  useMemo,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { authJsonQueryOptions } from "./authJsonQueryOptions";
import { convexQueryClient } from "./convex-query-client";
import { decodeJwt } from "jose";

function OnReadyComponent({ onReady }: { onReady: () => void }) {
  useEffect(() => {
    console.log("[ConvexClientProvider] Authenticated, boot ready");
    onReady();
  }, [onReady]);
  return null;
}

function useAuthFromStack() {
  const user = useUser();
  const authJsonQuery = useSuspenseQuery({
    ...authJsonQueryOptions(),
  });
  const isLoading = false;
  const isAuthenticated = useMemo(() => !!user, [user]);
  // Important: keep this function identity stable unless auth context truly changes.
  const fetchAccessToken = useCallback(
    async (opts: { forceRefreshToken: boolean }) => {
      // Helper to fetch a fresh token from Stack
      const fetchFresh = async () => {
        try {
          const fresh = await user?.getAuthJson();
          return fresh?.accessToken ?? null;
        } catch (_err) {
          console.warn("[ConvexAuth] Failed to fetch fresh token", _err);
          return null;
        }
      };

      if (opts.forceRefreshToken) {
        return await fetchFresh();
      }

      const cached = authJsonQuery.data?.accessToken ?? null;
      if (!cached) {
        return await fetchFresh();
      }

      try {
        const payload = decodeJwt(cached);
        const exp = typeof payload.exp === "number" ? payload.exp : undefined;
        const nowSec = Date.now() / 1000;
        // Refresh if within 60s of expiry
        if (exp && exp - nowSec <= 60) {
          return await fetchFresh();
        }
      } catch (_err) {
        // If we can't decode, fall back to fresh
        return await fetchFresh();
      }

      return cached;
    },
    [authJsonQuery.data, user]
  );

  const authResult = useMemo(
    () => ({
      isLoading,
      isAuthenticated,
      fetchAccessToken,
    }),
    [isAuthenticated, isLoading, fetchAccessToken]
  );
  return authResult;
}

function AuthenticatedOrSignIn({
  children,
  onReady,
}: {
  children: ReactNode;
  onReady: () => void;
}) {
  const user = useUser({ or: "return-null" });
  const showSignIn = !user;

  return (
    <>
      <AnimatePresence mode="wait">
        {showSignIn ? (
          <motion.div
            key="signin"
            className="absolute inset-0 w-screen h-dvh flex items-center justify-center bg-white dark:bg-black z-[99999999]"
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
                    const origin = env.NEXT_PUBLIC_WWW_ORIGIN;
                    const url = `${origin}/handler/sign-in/`;
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
      <Authenticated>
        <OnReadyComponent onReady={onReady} />
        {children}
      </Authenticated>
    </>
  );
}

export function ConvexClientProvider({ children }: { children: ReactNode }) {
  const [bootReady, setBootReady] = useState(false);
  const onBootReady = useCallback(() => {
    setBootReady(true);
  }, []);

  return (
    <>
      <AnimatePresence mode="sync" initial={false}>
        {!bootReady ? (
          <motion.div
            key="boot-loader"
            className="absolute inset-0 w-screen h-dvh flex flex-col items-center justify-center bg-white dark:bg-black z-[99999999]"
            initial={{ opacity: 1 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.22, ease: "easeOut" }}
          >
            <CmuxLogoMark height={40} />
            <pre className="text-xs font-mono text-neutral-200 dark:text-neutral-800 absolute bottom-0 left-0 pl-4 pb-4">
              {getRandomKitty()}
            </pre>
          </motion.div>
        ) : null}
      </AnimatePresence>
      <Suspense fallback={null}>
        <ConvexProviderWithAuth
          client={convexQueryClient.convexClient}
          useAuth={useAuthFromStack}
        >
          <AuthenticatedOrSignIn onReady={onBootReady}>
            {children}
          </AuthenticatedOrSignIn>
        </ConvexProviderWithAuth>
      </Suspense>
    </>
  );
}
