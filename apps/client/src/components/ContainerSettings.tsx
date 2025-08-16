import { api } from "@cmux/convex/api";
import { Switch } from "@heroui/react";
import { useQuery } from "convex/react";
import { Loader2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";

interface ContainerSettingsProps {
  onDataChange?: (data: {
    maxRunningContainers: number;
    reviewPeriodMinutes: number;
    autoCleanupEnabled: boolean;
    stopImmediatelyOnCompletion: boolean;
    minContainersToKeep: number;
  }) => void;
}

export function ContainerSettings({ onDataChange }: ContainerSettingsProps) {
  const settings = useQuery(api.containerSettings.get);
  const isInitialized = useRef(false);

  const [formData, setFormData] = useState({
    maxRunningContainers: 5,
    reviewPeriodMinutes: 60,
    autoCleanupEnabled: true,
    stopImmediatelyOnCompletion: false,
    minContainersToKeep: 0,
  });

  useEffect(() => {
    if (settings && !isInitialized.current) {
      const newData = {
        maxRunningContainers: settings.maxRunningContainers ?? 5,
        reviewPeriodMinutes: settings.reviewPeriodMinutes ?? 60,
        autoCleanupEnabled: settings.autoCleanupEnabled ?? true,
        stopImmediatelyOnCompletion:
          settings.stopImmediatelyOnCompletion ?? false,
        minContainersToKeep: settings.minContainersToKeep ?? 0,
      };
      setFormData(newData);
      onDataChange?.(newData);
      isInitialized.current = true;
    }
  }, [settings, onDataChange]);

  const updateFormData = (newData: typeof formData) => {
    setFormData(newData);
    onDataChange?.(newData);
  };

  if (!settings) {
    return (
      <div className="flex justify-center p-4">
        <Loader2 className="animate-spin" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div>
        <h3 className="text-lg font-medium">Container Lifecycle Settings</h3>
        <p className="text-sm text-muted-foreground">
          Configure how Docker containers are managed after tasks complete.
        </p>
      </div>

      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <div className="space-y-0.5">
            <label htmlFor="auto-cleanup" className="text-sm font-medium">
              Automatic Cleanup
            </label>
            <p className="text-sm text-muted-foreground">
              Automatically stop containers based on the rules below
            </p>
          </div>
          <Switch
            id="auto-cleanup"
            isSelected={formData.autoCleanupEnabled}
            onValueChange={(value) =>
              updateFormData({
                ...formData,
                autoCleanupEnabled: value,
              })
            }
            size="sm"
            classNames={{
              wrapper: "group-data-[selected=true]:bg-blue-600",
            }}
          />
        </div>

        <div className="space-y-2">
          <label htmlFor="max-containers" className="block text-sm font-medium">
            Maximum Running Containers
          </label>
          <input
            id="max-containers"
            type="number"
            min="1"
            max="20"
            value={formData.maxRunningContainers}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              updateFormData({
                ...formData,
                maxRunningContainers: parseInt(e.target.value, 10),
              })
            }
            disabled={!formData.autoCleanupEnabled}
            className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 disabled:opacity-50"
          />
          <p className="text-sm text-muted-foreground">
            Keep only the N most recently accessed containers running
          </p>
        </div>

        <div className="flex items-center justify-between">
          <div className="space-y-0.5">
            <label htmlFor="stop-immediately" className="text-sm font-medium">
              Stop Immediately on Completion
            </label>
            <p className="text-sm text-muted-foreground">
              Stop containers as soon as tasks complete (no review period)
            </p>
          </div>
          <Switch
            id="stop-immediately"
            isSelected={formData.stopImmediatelyOnCompletion}
            onValueChange={(value) =>
              updateFormData({
                ...formData,
                stopImmediatelyOnCompletion: value,
              })
            }
            isDisabled={!formData.autoCleanupEnabled}
            size="sm"
            classNames={{
              wrapper: "group-data-[selected=true]:bg-blue-600",
            }}
          />
        </div>

        <div className="space-y-2">
          <label htmlFor="min-containers" className="block text-sm font-medium">
            Always Keep Recent Containers
          </label>
          <input
            id="min-containers"
            type="number"
            min="0"
            max="20"
            value={formData.minContainersToKeep}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              updateFormData({
                ...formData,
                minContainersToKeep: parseInt(e.target.value, 10),
              })
            }
            disabled={!formData.autoCleanupEnabled}
            className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 disabled:opacity-50"
          />
          <p className="text-sm text-muted-foreground">
            Always keep the N most recent containers alive, regardless of review
            period (0 = disabled)
          </p>
        </div>

        <div className="space-y-2">
          <label htmlFor="review-period" className="block text-sm font-medium">
            Review Period (minutes)
          </label>
          <input
            id="review-period"
            type="number"
            min="10"
            max="2880"
            value={formData.reviewPeriodMinutes}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              updateFormData({
                ...formData,
                reviewPeriodMinutes: parseInt(e.target.value, 10),
              })
            }
            disabled={
              !formData.autoCleanupEnabled ||
              formData.stopImmediatelyOnCompletion
            }
            className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 disabled:opacity-50"
          />
          <p className="text-sm text-muted-foreground">
            {formData.stopImmediatelyOnCompletion
              ? "Review period is disabled when stopping immediately"
              : "Keep containers running for this many minutes after task completion to allow code review"}
          </p>
        </div>
      </div>
    </div>
  );
}
