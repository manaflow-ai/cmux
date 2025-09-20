"use client";

import { getRandomKitty } from "@/components/kitties";
import CmuxLogoMarkAnimated from "@/components/logo/cmux-logo-mark-animated";
import { cachedGetUser } from "@/lib/cachedGetUser";
import { isElectron } from "@/lib/electron";
import { stackClientApp } from "@/lib/stack";
import { WWW_ORIGIN } from "@/lib/wwwOrigin";
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
import { signalConvexAuthReady } from "./convex-auth-ready";
import { convexQueryClient } from "./convex-query-client";

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
  const accessToken = authJsonQuery.data?.accessToken ?? null;
  // Only consider authenticated once an access token is available.
  const isAuthenticated = useMemo(
    () => Boolean(user && accessToken),
    [user, accessToken]
  );
  // Important: keep this function identity stable unless auth context truly changes.
  const fetchAccessToken = useCallback(
    async (_opts: { forceRefreshToken: boolean }) => {
      const cached = authJsonQuery.data;
      if (cached?.accessToken) {
        return cached.accessToken;
      }
      // Fallback: directly ask Stack for a fresh token in case the cache is stale
      const u = await cachedGetUser(stackClientApp);
      const fresh = await u?.getAuthJson();
      return fresh?.accessToken ?? null;
    },
    [authJsonQuery.data]
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
                    const url = `${WWW_ORIGIN}/handler/sign-in/`;
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
    signalConvexAuthReady(true);
    setBootReady(true);
  }, []);

  return (
    <>
      <AnimatePresence mode="sync" initial={false}>
        {!bootReady ? (
          <motion.div
            key="boot-loader"
            className="absolute inset-0 w-screen h-dvh flex flex-col items-center justify-center bg-white dark:bg-black z-[var(--z-global-blocking)]"
            initial={{ opacity: 1 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.22, ease: "easeOut" }}
          >
            <CmuxLogoMarkAnimated height={40} duration={2.9} />
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
