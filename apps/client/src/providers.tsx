import { ThemeProvider } from "@/components/theme/theme-provider";
import { HeroUIProvider } from "@heroui/react";
import { StackProvider, StackTheme } from "@stackframe/react";
import { QueryClientProvider } from "@tanstack/react-query";
import {
  ConfigProvider as AntdConfigProvider,
  theme,
  type ThemeConfig,
} from "antd";
import { type ReactNode, Suspense, useEffect, useMemo, useState } from "react";
import { queryClient } from "./query-client";
import { stackClientApp } from "./stack";

interface ProvidersProps {
  children: ReactNode;
}

export function Providers({ children }: ProvidersProps) {
  const [isDarkMode, setIsDarkMode] = useState(false);

  useEffect(() => {
    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    setIsDarkMode(mediaQuery.matches);

    const handleChange = (e: MediaQueryListEvent) => {
      setIsDarkMode(e.matches);
    };

    mediaQuery.addEventListener("change", handleChange);
    return () => mediaQuery.removeEventListener("change", handleChange);
  }, []);

  useEffect(() => {
    const root = document.documentElement;
    const observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => {
        if (
          mutation.type === "attributes" &&
          mutation.attributeName === "class"
        ) {
          setIsDarkMode(root.classList.contains("dark"));
        }
      });
    });

    observer.observe(root, {
      attributes: true,
      attributeFilter: ["class"],
    });

    setIsDarkMode(root.classList.contains("dark"));

    return () => observer.disconnect();
  }, []);

  const antdTheme: ThemeConfig = useMemo(() => {
    return {
      algorithm: isDarkMode ? theme.darkAlgorithm : theme.defaultAlgorithm,
      components: {
        Select: {
          motion: true,
        },
        Dropdown: {
          motion: true,
        },
      },
    };
  }, [isDarkMode]);

  return (
    <ThemeProvider>
      <StackTheme>
        <Suspense fallback={<div>Loading stack...</div>}>
          <StackProvider app={stackClientApp}>
            <QueryClientProvider client={queryClient}>
              <HeroUIProvider>
                <AntdConfigProvider theme={antdTheme}>
                  {children}
                </AntdConfigProvider>
              </HeroUIProvider>
            </QueryClientProvider>
          </StackProvider>
        </Suspense>
      </StackTheme>
    </ThemeProvider>
  );
}
