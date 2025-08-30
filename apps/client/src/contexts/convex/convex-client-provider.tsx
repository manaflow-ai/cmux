"use client";

import { getRandomKitty } from "@/components/kitties";
import CmuxLogoMark from "@/components/logo/cmux-logo-mark";
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
  type ReactNode,
} from "react";
import { authJsonQueryOptions } from "./authJsonQueryOptions";
import { convexQueryClient } from "./convex-query-client";

function OnReadyComponent({ onReady }: { onReady: () => void }) {
  useEffect(() => {
    onReady();
  }, [onReady]);
  return null;
}

function useAuthFromStack() {
  const user = useUser();
  const authJsonQuery = useSuspenseQuery({
    ...authJsonQueryOptions(user),
  });
  const isLoading = false;
  const isAuthenticated = useMemo(() => !!user, [user]);
  // Important: keep this function identity stable unless auth context truly changes.
  const fetchAccessToken = useCallback(
    async (_opts: { forceRefreshToken: boolean }) => {
      const cached = authJsonQuery.data;
      if (cached && typeof cached === "object" && "accessToken" in cached) {
        return cached?.accessToken ?? null;
      }
      return null;
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
            className="absolute inset-0 w-screen h-dvh flex items-center justify-center bg-white dark:bg-black z-[99999999]"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2, ease: "easeOut" }}
          >
            <SignIn />
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
