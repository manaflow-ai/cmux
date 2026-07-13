// Copyright (c) 2024 Marshall A. Greenblatt. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the name Chromium Embedded
// Framework nor the names of its contributors may be used to endorse
// or promote products derived from this software without specific prior
// written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// ---------------------------------------------------------------------------
//
// The contents of this file must follow a specific format in order to
// support the CEF translator tool. See the translator.README.txt file in the
// tools directory for more information.
//

#ifndef CEF_INCLUDE_CEF_TASK_MANAGER_H_
#define CEF_INCLUDE_CEF_TASK_MANAGER_H_
#pragma once

#include <vector>

#include "include/cef_base.h"

///
/// Class that facilitates managing the browser-related tasks.
/// The methods of this class may only be called on the UI thread.
///
/*--cef(source=library)--*/
class CefTaskManager : public virtual CefBaseRefCounted {
 public:
  typedef std::vector<int64_t> TaskIdList;
  typedef cef_task_type_t TaskType;

  ///
  /// Returns the global task manager object.
  /// Returns nullptr if the method was called from the incorrect thread.
  ///
  /*--cef()--*/
  static CefRefPtr<CefTaskManager> GetTaskManager();

  ///
  /// Returns the number of tasks currently tracked by the task manager.
  /// Returns 0 if the method was called from the incorrect thread.
  ///
  /*--cef()--*/
  virtual size_t GetTasksCount() = 0;

  ///
  /// Gets the list of task IDs currently tracked by the task manager. Tasks
  /// that share the same process id will always be consecutive. The list will
  /// be sorted in a way that reflects the process tree: the browser process
  /// will be first, followed by the gpu process if it exists. Related processes
  /// (e.g., a subframe process and its parent) will be kept together if
  /// possible. Callers can expect this ordering to be stable when a process is
  /// added or removed. The task IDs are unique within the application lifespan.
  /// Returns false if the method was called from the incorrect thread.
  ///
  /*--cef(count_func=task_ids:GetTasksCount)--*/
  virtual bool GetTaskIdsList(TaskIdList& task_ids) = 0;

  ///
  /// Gets information about the task with |task_id|.
  /// Returns true if the information about the task was successfully
  /// retrieved and false if the |task_id| is invalid or the method was called
  /// from the incorrect thread.
  ///
  /*--cef()--*/
  virtual bool GetTaskInfo(int64_t task_id, CefTaskInfo& info) = 0;

  ///
  /// Attempts to terminate a task with |task_id|.
  /// Returns false if the |task_id| is invalid, the call is made from an
  /// incorrect thread, or if the task cannot be terminated.
  ///
  /*--cef()--*/
  virtual bool KillTask(int64_t task_id) = 0;

  ///
  /// Returns the task ID associated with the main task for |browser_id|
  /// (value from CefBrowser::GetIdentifier). Returns -1 if |browser_id| is
  /// invalid, does not currently have an associated task, or the method was
  /// called from the incorrect thread.
  ///
  /*--cef()--*/
  virtual int64_t GetTaskIdForBrowserId(int browser_id) = 0;
};

#endif  // CEF_INCLUDE_CEF_TASK_MANAGER_H_
